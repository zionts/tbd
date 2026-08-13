import Foundation
import os

/// Accumulates keystroke → first-echo latency samples and logs a percentile
/// summary at most once per second.
///
/// This closes the one gap the external tmux probes could not reach. Probing
/// tmux directly showed transport at p50 0.22 ms / p99 1.84 ms, unchanged even
/// under heavy swap — so whatever the user perceives as input lag accrues
/// either inside the pane's own application (its redraw) or here, between the
/// bytes arriving and a glyph appearing. `InputLatencyRecorder` on the daemon
/// measures only the DELIVERY half (sidecar receipt → `send-keys` write) and
/// only exists on the control-mode path, which is off by default.
///
/// What is measured: the interval from a keystroke leaving `send(source:data:)`
/// to the first output arriving for the same panel. That is an UPPER BOUND on
/// echo latency, not an exact figure — the next output is usually the echo when
/// the user is typing, but an agent that writes on its own can land first and
/// close the interval early. Under-reporting is the safe direction: a
/// measurement that looks bad is therefore trustworthy, and one that looks good
/// warrants a second look.
///
/// Diagnostics only — nothing here feeds back into rendering or input. The
/// `now` seam lets tests drive the 1 Hz gate without real time, matching
/// `InputLatencyRecorder`.
final class EchoLatencyRecorder: @unchecked Sendable {
    struct Summary: Equatable {
        let count: Int
        let p50Ms: Double
        let p99Ms: Double
        let maxMs: Double
    }

    private let logger = Logger(subsystem: "com.tbd.app", category: "echoLatency")
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private let emitInterval: Duration

    private var samples: [Duration] = []
    /// Start of the current summary window. `nil` until the first sample, which
    /// opens the window WITHOUT emitting (a summary needs a full interval).
    private var windowStart: ContinuousClock.Instant?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         emitInterval: Duration = .seconds(1)) {
        self.now = now
        self.emitInterval = emitInterval
    }

    /// Record one keystroke → first-echo sample. Emits (and resets) at most once
    /// per `emitInterval`; between emits, samples accumulate.
    func record(_ duration: Duration) {
        let summary: Summary?
        lock.lock()
        samples.append(duration)
        let current = now()
        guard let start = windowStart else {
            windowStart = current            // open the window; first sample never emits
            lock.unlock()
            return
        }
        guard current - start >= emitInterval else {
            lock.unlock()
            return
        }
        windowStart = current
        summary = summarizeAndResetLocked()
        lock.unlock()

        if let summary {
            logger.debug("""
                echo latency: n=\(summary.count, privacy: .public) \
                p50=\(summary.p50Ms, privacy: .public)ms \
                p99=\(summary.p99Ms, privacy: .public)ms \
                max=\(summary.maxMs, privacy: .public)ms
                """)
        }
    }

    /// Test seam: compute the current window's summary and clear it. Returns
    /// `nil` when no samples are buffered.
    func summarizeAndReset() -> Summary? {
        lock.lock()
        defer { lock.unlock() }
        return summarizeAndResetLocked()
    }

    private func summarizeAndResetLocked() -> Summary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let ms: (Duration) -> Double = { d in
            Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) / 1_000_000_000_000_000
        }
        // Nearest-rank percentiles, clamped — matches InputLatencyRecorder so
        // the two logs are directly comparable.
        let index: (Double) -> Int = { q in
            min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.down))))
        }
        let summary = Summary(
            count: sorted.count,
            p50Ms: ms(sorted[index(0.50)]),
            p99Ms: ms(sorted[index(0.99)]),
            maxMs: ms(sorted[sorted.count - 1])
        )
        samples.removeAll(keepingCapacity: true)
        return summary
    }
}

// MARK: - Keystroke classification

/// Decides whether an outgoing byte slice is a plain typed keystroke worth
/// timing. Extracted as a pure function so the classification is testable
/// without a live terminal.
enum EchoLatencyKeystroke {
    /// True for a short run of printable input — the case where the next output
    /// really is an echo. Deliberately excludes:
    /// - control bytes (< 0x20) and DEL (0x7F): Enter submits, Ctrl-C
    ///   interrupts, and arrows navigate. None produce a simple echo, and an
    ///   agent's response to them would be misread as one.
    /// - anything longer than a few bytes: pastes and bracketed sequences.
    static func isTimeable(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 4 else { return false }
        // A multi-byte UTF-8 scalar is fine; a control byte anywhere is not.
        return bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }
}
