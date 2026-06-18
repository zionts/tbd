import Testing
import Foundation
import TBDShared

/// Backward/forward-compat decode tests for the `senderKind` field added to
/// `ChannelMessage`, `ChannelPostParams`, and `ChannelMessageDelta`.
@Suite struct ChannelMessageSenderKindCodableTests {

    // MARK: - ChannelMessage

    /// CRITICAL: a message serialized before `senderKind` existed (field absent)
    /// must decode to `.agent`, not throw.
    @Test func channelMessageWithoutSenderKindDecodesToAgent() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "teamID": "\(UUID().uuidString)",
              "senderWorktreeID": "\(UUID().uuidString)",
              "type": "note",
              "body": "legacy",
              "createdAt": 0
            }
            """
        let decoder = JSONDecoder()
        let message = try decoder.decode(ChannelMessage.self, from: Data(json.utf8))
        #expect(message.senderKind == .agent)
    }

    @Test func channelMessageWithHumanSenderKindDecodes() throws {
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "teamID": "\(UUID().uuidString)",
              "senderWorktreeID": "\(UUID().uuidString)",
              "type": "note",
              "senderKind": "human",
              "body": "barge-in",
              "createdAt": 0
            }
            """
        let message = try JSONDecoder().decode(ChannelMessage.self, from: Data(json.utf8))
        #expect(message.senderKind == .human)
    }

    @Test func channelMessageRoundTripsHumanSenderKind() throws {
        let original = ChannelMessage(
            teamID: UUID(),
            senderWorktreeID: UUID(),
            type: .note,
            senderKind: .human,
            body: "hi"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelMessage.self, from: data)
        #expect(decoded.senderKind == .human)
        #expect(decoded == original)
    }

    // MARK: - ChannelSenderKind unknown-value fallback

    @Test func unknownSenderKindFallsBackToAgent() throws {
        let json = "\"telepath\""
        let kind = try JSONDecoder().decode(ChannelSenderKind.self, from: Data(json.utf8))
        #expect(kind == .agent)
    }

    // MARK: - ChannelPostParams

    @Test func postParamsWithoutSenderKindDefaultsToAgent() throws {
        let json = """
            { "senderWorktreeID": "\(UUID().uuidString)", "type": "note", "body": "x" }
            """
        let params = try JSONDecoder().decode(ChannelPostParams.self, from: Data(json.utf8))
        #expect(params.senderKind == .agent)
    }

    @Test func postParamsRoundTripsHuman() throws {
        let original = ChannelPostParams(
            senderWorktreeID: UUID(), type: .note, senderKind: .human, body: "x")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelPostParams.self, from: data)
        #expect(decoded.senderKind == .human)
    }

    // MARK: - ChannelMessageDelta

    @Test func deltaWithoutSenderKindDecodesToAgent() throws {
        let json = """
            {
              "messageID": "\(UUID().uuidString)",
              "teamID": "\(UUID().uuidString)",
              "senderWorktreeID": "\(UUID().uuidString)",
              "type": "note",
              "body": "x",
              "createdAt": 0
            }
            """
        let delta = try JSONDecoder().decode(ChannelMessageDelta.self, from: Data(json.utf8))
        #expect(delta.senderKind == .agent)
    }

    @Test func deltaFromHumanMessageCarriesSenderKind() throws {
        let message = ChannelMessage(
            teamID: UUID(),
            senderWorktreeID: UUID(),
            type: .note,
            senderKind: .human,
            body: "x"
        )
        let delta = ChannelMessageDelta(from: message)
        #expect(delta.senderKind == .human)
        // And it survives a Codable round-trip.
        let data = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(ChannelMessageDelta.self, from: data)
        #expect(decoded.senderKind == .human)
    }
}
