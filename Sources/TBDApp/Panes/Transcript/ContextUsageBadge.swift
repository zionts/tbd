import SwiftUI
import TBDShared

/// Diminutive subscript line shown beneath the latest top-level assistant
/// item in the transcript viewer. Displays the total prompt size
/// (input + cache_creation + cache_read tokens) of that turn's API call
/// against the model's context window, e.g. `186k / 200k (93%)`. When the
/// window is unknown (no/non-Claude model) it falls back to `Nk tokens`.
///
/// See `docs/transcript-context-usage.md` for the underlying mechanism.
struct ContextUsageBadge: View {
    let total: Int
    let model: String?

    var body: some View {
        Text(Self.formatted(total: total, model: model))
            .foregroundStyle(.secondary)
            .font(.system(size: 9))
            .fontWeight(.regular)
            .opacity(0.7)
    }

    /// Whole-thousands abbreviation with the model's window as denominator:
    /// `186k / 200k (93%)`. Window rules:
    /// - unknown model → legacy `186k tokens`
    /// - total ≤ standard window → `total / 200k (p%)`
    /// - total > standard window → the session evidently runs the 1M-context
    ///   beta (invisible in the model string), so upgrade the denominator:
    ///   `270k / 1000k (27%)`
    /// - total > 1M too → legacy fallback, never a lying >100% figure.
    nonisolated static func formatted(total: Int, model: String?) -> String {
        guard let window = ClaudeContextWindow.limit(forModel: model) else {
            return "\(total / 1000)k tokens"
        }
        let effectiveWindow = total <= window ? window : ClaudeContextWindow.extendedLimit
        guard total <= effectiveWindow else {
            return "\(total / 1000)k tokens"
        }
        let percent = Int((Double(total) / Double(effectiveWindow) * 100).rounded())
        return "\(total / 1000)k / \(effectiveWindow / 1000)k (\(percent)%)"
    }
}

// MARK: - Preview

/// Uses `PreviewProvider` (not the `#Preview` macro) so the file still
/// compiles under bare `swift build` — the SPM toolchain doesn't ship the
/// `PreviewsMacros` plugin that Xcode injects.
struct ContextUsageBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 4) {
            ContextUsageBadge(total: 12_345, model: nil)
            ContextUsageBadge(total: 186_000, model: "claude-fable-5")
            ContextUsageBadge(total: 200_000, model: "claude-opus-4-8")
            ContextUsageBadge(total: 270_000, model: "claude-sonnet-4-6")
            ContextUsageBadge(total: 1_500_000, model: "claude-opus-4-6")
        }
        .padding()
        .previewDisplayName("ContextUsageBadge")
    }
}
