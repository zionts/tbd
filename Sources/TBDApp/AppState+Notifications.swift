import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notifications")

extension AppState {
    // MARK: - Notification Actions

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil,
                terminalID: UUID? = nil) async {
        do {
            try await daemonClient.notify(worktreeID: worktreeID, type: type,
                                          message: message, terminalID: terminalID)
        } catch {
            logger.error("Failed to send notification: \(error)")
            handleConnectionError(error)
        }
    }

    /// Handle a notification emitted by a terminal itself (OSC-777, a bell, or
    /// a title change) and bridged from the blit web client. Delivers a native
    /// banner only when the terminal's worktree is NOT currently visible —
    /// matching the old SwiftTerm behavior, which only notified when the
    /// terminal's window wasn't key. The banner collapses per-worktree and
    /// routes to the originating terminal on click.
    func handleTerminalNotification(terminalID: UUID, worktreeID: UUID,
                                    title: String, body: String) {
        // Suppress when the user is already looking at this worktree.
        guard !visibleWorktreeIDs.contains(worktreeID) else { return }

        let message: String
        if !body.isEmpty {
            message = title.isEmpty ? body : "\(title): \(body)"
        } else {
            message = title
        }
        guard !message.isEmpty else { return }

        macNotificationManager.postIfEnabled(
            worktreeID: worktreeID,
            message: message,
            worktrees: worktrees.values.flatMap { $0 },
            type: .responseComplete,
            terminalID: terminalID
        )
    }

    /// Mark all notifications for a worktree as read.
    func markNotificationsRead(worktreeID: UUID) async {
        do {
            try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
            unreadByWorktree[worktreeID] = nil
        } catch {
            // Not critical — just clear locally
            logger.warning("Failed to mark notifications read for \(worktreeID): \(error)")
            unreadByWorktree[worktreeID] = nil
        }
    }

    // MARK: - Daemon Status

    /// Get daemon status info.
    func fetchDaemonStatus() async -> DaemonStatusResult? {
        do {
            let status = try await daemonClient.daemonStatus()
            isConnected = true
            return status
        } catch {
            logger.error("Failed to get daemon status: \(error)")
            handleConnectionError(error)
            return nil
        }
    }

    // MARK: - Helpers

    func handleConnectionError(_ error: Error) {
        if let dcError = error as? DaemonClientError {
            switch dcError {
            case .daemonNotRunning, .connectionFailed:
                isConnected = false
            default:
                break
            }
        }
    }

    func showAlert(_ message: String, isError: Bool = false) {
        alertMessage = message
        alertIsError = isError
    }
}
