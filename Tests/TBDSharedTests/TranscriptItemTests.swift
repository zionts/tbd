import Foundation
import Testing
import TBDShared

@Suite("TranscriptItem Codable")
struct TranscriptItemTests {
    @Test func roundtrip_userPrompt() throws {
        let original: TranscriptItem = .userPrompt(id: "u1", text: "hello", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .userPrompt(let id, let text, _) = decoded else {
            Issue.record("expected .userPrompt"); return
        }
        #expect(id == "u1")
        #expect(text == "hello")
    }

    @Test func roundtrip_assistantText() throws {
        let original: TranscriptItem = .assistantText(id: "a1", text: "ok", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .assistantText(let id, let text, _, _) = decoded else {
            Issue.record("expected .assistantText"); return
        }
        #expect(id == "a1")
        #expect(text == "ok")
    }

    @Test func roundtrip_toolCall_no_subagent() throws {
        let result = ToolResult(text: "stdout", truncatedTo: nil, isError: false)
        let original: TranscriptItem = .toolCall(
            id: "toolu_1", name: "Read", inputJSON: "{\"file_path\":\"/x\"}",
            inputTruncatedTo: nil,
            result: result, subagent: nil, timestamp: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let r, let sub, _, _) = decoded else {
            Issue.record("expected .toolCall"); return
        }
        #expect(id == "toolu_1")
        #expect(name == "Read")
        #expect(inputJSON == "{\"file_path\":\"/x\"}")
        #expect(inputTruncatedTo == nil)
        #expect(r?.text == "stdout")
        #expect(sub == nil)
    }

    @Test func roundtrip_toolCall_with_subagent_with_nested_toolcall() throws {
        let inner: TranscriptItem = .toolCall(
            id: "toolu_inner", name: "Bash", inputJSON: "{}",
            inputTruncatedTo: nil,
            result: ToolResult(text: "ok", truncatedTo: nil, isError: false),
            subagent: nil, timestamp: nil
        )
        let sub = Subagent(agentID: "agent_x", agentType: "feature-dev:code-explorer", items: [inner])
        let outer: TranscriptItem = .toolCall(
            id: "toolu_outer", name: "Task", inputJSON: "{\"prompt\":\"…\"}",
            inputTruncatedTo: 50_000,
            result: ToolResult(text: "done", truncatedTo: nil, isError: false),
            subagent: sub, timestamp: nil
        )
        let data = try JSONEncoder().encode(outer)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .toolCall(_, _, _, let outerTruncated, _, let s, _, _) = decoded else {
            Issue.record("expected .toolCall"); return
        }
        #expect(outerTruncated == 50_000)
        #expect(s?.agentID == "agent_x")
        #expect(s?.items.count == 1)
    }

    @Test func roundtrip_thinking() throws {
        let original: TranscriptItem = .thinking(id: "t1", text: "musing", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .thinking(_, let text, _) = decoded else {
            Issue.record("expected .thinking"); return
        }
        #expect(text == "musing")
    }

    @Test func roundtrip_systemReminder() throws {
        let original: TranscriptItem = .systemReminder(id: "s1", kind: .toolReminder, text: "hi", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .systemReminder(_, let kind, _, _) = decoded else {
            Issue.record("expected .systemReminder"); return
        }
        #expect(kind == .toolReminder)
    }

    @Test func roundtrip_slashCommand() throws {
        let original: TranscriptItem = .slashCommand(id: "sc1", name: "rebase", args: "main", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .slashCommand(_, let name, let args, _) = decoded else {
            Issue.record("expected .slashCommand"); return
        }
        #expect(name == "rebase")
        #expect(args == "main")
    }

    @Test func toolResult_truncated_field_decodes() throws {
        let original = ToolResult(text: "first 2KB", truncatedTo: 50_000, isError: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.truncatedTo == 50_000)
        #expect(decoded.isError == false)
    }

    @Test func tokenUsage_decodes_json_without_model_key() throws {
        // Back-compat guard for the daemon→app RPC: JSON serialized before
        // the `model` field existed must still decode.
        let legacyJSON = Data(#"{"inputTokens":5,"cacheCreationTokens":1000,"cacheReadTokens":40000}"#.utf8)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: legacyJSON)
        #expect(decoded.model == nil)
        #expect(decoded.contextTotal == 41_005)
    }

    @Test func tokenUsage_roundtrips_model() throws {
        let original = TokenUsage(inputTokens: 1, cacheCreationTokens: 2, cacheReadTokens: 3, model: "claude-fable-5")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(decoded == original)
        #expect(decoded.model == "claude-fable-5")
    }
}

@Suite("ClaudeContextWindow")
struct ClaudeContextWindowTests {
    @Test func claude_prefixed_models_map_to_standard_window() {
        #expect(ClaudeContextWindow.limit(forModel: "claude-fable-5") == 200_000)
        #expect(ClaudeContextWindow.limit(forModel: "claude-opus-4-8") == 200_000)
        #expect(ClaudeContextWindow.limit(forModel: "claude-sonnet-4-6") == 200_000)
        // Prefix match is case-insensitive and permissive about suffixes.
        #expect(ClaudeContextWindow.limit(forModel: "Claude-Future-9") == 200_000)
    }

    @Test func unknown_models_map_to_nil() {
        #expect(ClaudeContextWindow.limit(forModel: nil) == nil)
        #expect(ClaudeContextWindow.limit(forModel: "<synthetic>") == nil)
        #expect(ClaudeContextWindow.limit(forModel: "gpt-5") == nil)
        #expect(ClaudeContextWindow.limit(forModel: "") == nil)
    }
}
