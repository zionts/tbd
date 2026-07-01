import Foundation
import Testing

@testable import TBDApp

@Suite("ContextUsageBadge")
struct ContextUsageBadgeTests {
    @Test func formatted_no_window_falls_back_to_legacy_tokens_form() {
        // Nil model, non-Claude model, and totals of any size all render the
        // legacy floor-thousands form when the window is unknown.
        #expect(ContextUsageBadge.formatted(total: 0, model: nil) == "0k tokens")
        #expect(ContextUsageBadge.formatted(total: 999, model: nil) == "0k tokens")
        #expect(ContextUsageBadge.formatted(total: 124_300, model: nil) == "124k tokens")
        #expect(ContextUsageBadge.formatted(total: 1_500_000, model: nil) == "1500k tokens")
        #expect(ContextUsageBadge.formatted(total: 124_300, model: "gpt-5") == "124k tokens")
    }

    @Test func formatted_known_model_shows_total_window_and_percent() {
        #expect(ContextUsageBadge.formatted(total: 186_000, model: "claude-fable-5")
                == "186k / 200k (93%)")
        #expect(ContextUsageBadge.formatted(total: 124_300, model: "claude-opus-4-8")
                == "124k / 200k (62%)")
    }

    @Test func formatted_total_equal_to_window_is_100_percent() {
        #expect(ContextUsageBadge.formatted(total: 200_000, model: "claude-sonnet-4-6")
                == "200k / 200k (100%)")
    }

    @Test func formatted_total_over_window_upgrades_denominator_to_1M() {
        // 1M-context sessions don't change the model string, so a total
        // beyond the standard window means the window must be the 1M beta —
        // never render a lying >100% figure.
        #expect(ContextUsageBadge.formatted(total: 270_000, model: "claude-sonnet-4-6")
                == "270k / 1000k (27%)")
        #expect(ContextUsageBadge.formatted(total: 200_001, model: "claude-sonnet-4-6")
                == "200k / 1000k (20%)")
        #expect(ContextUsageBadge.formatted(total: 1_000_000, model: "claude-sonnet-4-6")
                == "1000k / 1000k (100%)")
    }

    @Test func formatted_total_over_1M_falls_back_to_legacy_form() {
        #expect(ContextUsageBadge.formatted(total: 1_000_001, model: "claude-sonnet-4-6")
                == "1000k tokens")
        #expect(ContextUsageBadge.formatted(total: 1_500_000, model: "claude-opus-4-6")
                == "1500k tokens")
    }

    @Test func formatted_percent_uses_standard_rounding() {
        // 92.5% rounds away from zero to 93; 92.4% rounds down to 92.
        #expect(ContextUsageBadge.formatted(total: 185_000, model: "claude-fable-5")
                == "185k / 200k (93%)")
        #expect(ContextUsageBadge.formatted(total: 184_800, model: "claude-fable-5")
                == "184k / 200k (92%)")
        // 0.5% rounds up to 1%.
        #expect(ContextUsageBadge.formatted(total: 1_000, model: "claude-fable-5")
                == "1k / 200k (1%)")
    }
}
