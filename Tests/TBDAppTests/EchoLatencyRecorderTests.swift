import Foundation
import Testing
@testable import TBDApp

// MARK: - Keystroke classification

@Test func isTimeable_plainPrintableKeystroke_isTimed() {
    #expect(EchoLatencyKeystroke.isTimeable(Array("a".utf8)[...]))
    #expect(EchoLatencyKeystroke.isTimeable(Array("Z".utf8)[...]))
    #expect(EchoLatencyKeystroke.isTimeable(Array(" ".utf8)[...]))
    // A multi-byte UTF-8 scalar is still one typed character.
    #expect(EchoLatencyKeystroke.isTimeable(Array("é".utf8)[...]))
}

@Test func isTimeable_controlBytes_areNotTimed() {
    // Enter submits, Ctrl-C interrupts, Esc/arrows navigate. None yields a
    // simple echo, so timing them would misattribute the agent's RESPONSE as
    // echo latency and report wildly inflated numbers.
    #expect(!EchoLatencyKeystroke.isTimeable([0x0D][...]))        // Enter
    #expect(!EchoLatencyKeystroke.isTimeable([0x03][...]))        // Ctrl-C
    #expect(!EchoLatencyKeystroke.isTimeable([0x1B][...]))        // Esc
    #expect(!EchoLatencyKeystroke.isTimeable([0x1B, 0x5B, 0x41][...]))  // Up arrow
    #expect(!EchoLatencyKeystroke.isTimeable([0x7F][...]))        // DEL
}

@Test func isTimeable_emptyOrBulk_isNotTimed() {
    #expect(!EchoLatencyKeystroke.isTimeable([][...]))
    // Longer than a keystroke — a paste, whose echo is a different animal.
    #expect(!EchoLatencyKeystroke.isTimeable(Array("hello world".utf8)[...]))
}

// MARK: - Percentile math

@Test func summarize_computesPercentilesOverRecordedSamples() {
    let recorder = EchoLatencyRecorder()
    for ms in 1...100 {
        recorder.record(.milliseconds(ms))
    }
    let summary = try? #require(recorder.summarizeAndReset())
    #expect(summary?.count == 100)
    #expect((summary?.maxMs ?? 0) == 100.0)
    // Nearest-rank: p50 of 1...100 lands on the 51st element.
    #expect(abs((summary?.p50Ms ?? 0) - 51.0) < 0.001)
    #expect(abs((summary?.p99Ms ?? 0) - 100.0) < 0.001)
}

@Test func summarize_withNoSamples_returnsNil() {
    #expect(EchoLatencyRecorder().summarizeAndReset() == nil)
}

@Test func summarize_clearsBufferSoWindowsDoNotAccumulate() {
    let recorder = EchoLatencyRecorder()
    recorder.record(.milliseconds(5))
    _ = recorder.summarizeAndReset()
    // A second window must not re-report the first window's sample.
    #expect(recorder.summarizeAndReset() == nil)
}

/// Mutable clock for the injected `now` seam. A plain `var` captured by the
/// `@Sendable` closure is not expressible; a reference box is.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return instant
    }
    func advance(by duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

@Test func record_firstSampleOpensWindowWithoutEmitting() {
    // The 1 Hz gate is driven by an injected clock: the first sample opens the
    // window, so a summary always covers a full interval rather than firing on
    // a single unrepresentative measurement.
    let clock = ClockBox()
    let recorder = EchoLatencyRecorder(now: { clock.now }, emitInterval: .seconds(1))
    recorder.record(.milliseconds(10))
    // Still buffered — the window-opening sample neither emits nor clears.
    #expect(recorder.summarizeAndReset()?.count == 1)
}

@Test func record_emitsAndClearsOnlyAfterTheIntervalElapses() {
    let clock = ClockBox()
    let recorder = EchoLatencyRecorder(now: { clock.now }, emitInterval: .seconds(1))
    recorder.record(.milliseconds(10))   // opens the window
    recorder.record(.milliseconds(20))   // same window: buffered, not emitted
    #expect(recorder.summarizeAndReset()?.count == 2)

    recorder.record(.milliseconds(30))   // reopens
    clock.advance(by: .seconds(2))
    recorder.record(.milliseconds(40))   // interval elapsed -> emits and clears
    #expect(recorder.summarizeAndReset() == nil)
}
