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
                // A human barge-in is just plain text — no type picker. The glyph
                // signals "you, the human, are posting" to mirror how human
                // messages render in the list (see ThreadMessageRow).
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("You'll post to the team channel as a human")

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
        // Optimistically clear the composer, but keep `body` so we can restore the
        // exact text on failure — clearing-before-await previously discarded the
        // user's message silently when the post threw.
        draft = ""
        sendFailed = false
        isSending = true
        composerFocused = true
        Task {
            // Human barge-in: always `.human`, with `.note` as the under-the-hood
            // type (the human never picks one). senderWorktreeID still scopes the
            // team; senderKind is what attributes the post to the user.
            let ok = await appState.postChannelMessage(
                senderWorktreeID: worktreeID, type: .note, senderKind: .human, body: body
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

// MARK: - Row presentation (pure, testable)

/// Pure rendering decision for one channel message row, factored out of the
/// SwiftUI view so the human-vs-agent branch is unit-testable without a view
/// host. Chat convention: a human's own posts are offset (right-aligned,
/// accented, labelled "You", no type badge); agent posts keep the worktree name
/// + a `[TYPE]` badge.
struct ThreadMessageRowStyle: Equatable {
    let isHuman: Bool
    /// Author shown in the row header. "You" for a human; the worktree name for
    /// an agent.
    let authorLabel: String
    /// Whether to render the `[TYPE]` badge. Suppressed for human posts (the
    /// human never picks a type).
    let showsTypeBadge: Bool

    init(senderKind: ChannelSenderKind, senderName: String) {
        switch senderKind {
        case .human:
            self.isHuman = true
            self.authorLabel = "You"
            self.showsTypeBadge = false
        case .agent:
            self.isHuman = false
            self.authorLabel = senderName
            self.showsTypeBadge = true
        }
    }
}

// MARK: - Message row

private struct ThreadMessageRow: View {
    let message: ChannelMessage
    let senderName: String

    private var style: ThreadMessageRowStyle {
        ThreadMessageRowStyle(senderKind: message.senderKind, senderName: senderName)
    }

    var body: some View {
        // Human posts are offset to the trailing edge (chat convention: your own
        // messages sit on the right); agent posts stay leading-aligned.
        HStack(spacing: 0) {
            if style.isHuman { Spacer(minLength: 40) }
            bubble
            if !style.isHuman { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if style.isHuman {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
                Text(style.authorLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.isHuman ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if style.showsTypeBadge {
                    typeTag
                }
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
        .padding(.horizontal, style.isHuman ? 10 : 0)
        .padding(.vertical, style.isHuman ? 7 : 0)
        .background(humanBackground)
    }

    @ViewBuilder
    private var humanBackground: some View {
        if style.isHuman {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        }
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
