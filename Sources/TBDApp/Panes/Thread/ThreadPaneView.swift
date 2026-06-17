import SwiftUI
import TBDShared

/// Live team coordination-channel pane (orchestration spine Phase C).
///
/// Renders the append-only channel for the pane's worktree's team: a scrolling
/// list of messages that auto-scrolls to newest and live-updates from
/// `AppState.channelMessages`, plus a bottom post box that lets the human
/// "barge in" by posting a `.note` (or any typed message) as the worktree.
///
/// `worktreeID` is the pane's own worktree. The daemon resolves it to the shared
/// `teamID`; `backfillChannel` returns that resolved id, which we hold in
/// `resolvedTeamID` so reads key on the same bucket the deltas land in.
struct ThreadPaneView: View {
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    @State private var resolvedTeamID: UUID?
    @State private var draft: String = ""
    @State private var selectedType: ChannelMessageType = .note
    @State private var isSending = false
    /// Set when a post fails so the composer can surface an inline error and the
    /// user can retry. Cleared on the next send attempt or successful post. The
    /// typed text is restored to `draft` on failure, so nothing is lost.
    @State private var sendFailed = false
    @FocusState private var composerFocused: Bool

    /// Messages for this pane's team. Until the backfill resolves the team root
    /// we fall back to keying on the worktree id (correct when this worktree is
    /// itself the team root, and harmless otherwise — it just shows empty until
    /// the resolved id arrives a beat later).
    private var messages: [ChannelMessage] {
        let key = resolvedTeamID ?? worktreeID
        return appState.channelMessages[key] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: worktreeID) {
            resolvedTeamID = await appState.backfillChannel(worktreeID: worktreeID)
        }
    }

    // MARK: - Message list

    @ViewBuilder
    private var messageList: some View {
        if messages.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No team messages yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Coordination posts from this team's agents appear here. Send one below to barge in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            ThreadMessageRow(
                                message: message,
                                senderName: senderName(for: message.senderWorktreeID)
                            )
                            .id(message.id)
                        }
                        // Anchor for auto-scroll to the very bottom.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    private static let bottomAnchorID = "thread-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - Composer (human barge-in)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sendFailed {
                // Inline failure affordance: the post failed and the typed text has
                // been restored to the composer. Pressing send again retries.
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("Couldn't send — your message is still here. Press send to retry.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(ThreadMessageType.allDisplayed, id: \.self) { type in
                        Button {
                            selectedType = type
                        } label: {
                            Label(type.displayLabel, systemImage: type == selectedType ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ThreadMessageType.color(for: selectedType))
                            .frame(width: 7, height: 7)
                        Text(selectedType.displayLabel)
                            .font(.caption)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isSending)
                .help("Message type")

                TextField("Message the team…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit(send)
                    // Disable while a post is in flight so Return can't re-enter
                    // send() and double-post (or post during the await window).
                    .disabled(isSending)
                    .opacity(isSending ? 0.5 : 1)

                Button(action: send) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .help("Send to team channel")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: sendFailed)
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isSending else { return }
        let type = selectedType
        // Optimistically clear the composer, but keep `body` so we can restore the
        // exact text on failure — clearing-before-await previously discarded the
        // user's message silently when the post threw.
        draft = ""
        sendFailed = false
        isSending = true
        composerFocused = true
        Task {
            let ok = await appState.postChannelMessage(
                senderWorktreeID: worktreeID, type: type, body: body
            )
            isSending = false
            if !ok {
                // Restore the typed text and surface the failure inline. Don't
                // clobber anything the user typed into the (disabled) field while
                // the post was in flight — only restore when it's still empty.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = body
                }
                sendFailed = true
                composerFocused = true
            }
        }
    }

    // MARK: - Sender resolution

    /// Short, human-readable name for a sender worktree. Falls back to a short
    /// prefix of the UUID when the worktree isn't in the local model (e.g. a
    /// teammate's worktree this client doesn't track).
    private func senderName(for id: UUID) -> String {
        if let wt = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.id == id }) {
            return wt.displayName
        }
        return String(id.uuidString.prefix(8))
    }
}

// MARK: - Message row

private struct ThreadMessageRow: View {
    let message: ChannelMessage
    let senderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(senderName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                typeTag
                Spacer(minLength: 4)
                Text(ThreadMessageType.timeString(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.body)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeTag: some View {
        Text(message.type.displayLabel.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ThreadMessageType.color(for: message.type))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(ThreadMessageType.color(for: message.type).opacity(0.15))
            )
    }
}

// MARK: - Type presentation

/// Presentation helpers for `ChannelMessageType`. Kept in the app layer (not the
/// shared model) so colors/labels stay a UI concern.
private enum ThreadMessageType {
    /// Types offered in the composer picker, in a sensible barge-in order.
    static let allDisplayed: [ChannelMessageType] = [.note, .blocker, .start, .pr, .done, .learning]

    static func color(for type: ChannelMessageType) -> Color {
        switch type {
        case .start: return .blue
        case .blocker: return .red
        case .pr: return .purple
        case .done: return .green
        case .learning: return .orange
        case .note: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

private extension ChannelMessageType {
    var displayLabel: String {
        switch self {
        case .start: return "Start"
        case .blocker: return "Blocker"
        case .pr: return "PR"
        case .done: return "Done"
        case .learning: return "Learning"
        case .note: return "Note"
        }
    }
}
