import Testing

@testable import TBDApp
import TBDShared

@Suite("RowStatusIndicator")
struct RowStatusIndicatorTests {
    @Test func pendingWinsOverEverything() {
        let result = RowStatusIndicator.resolve(
            isPending: true,
            isWorking: true,
            notification: .error,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .pending)
    }

    @Test func workingWinsOverLowSeverityNotificationSuspendedAndPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: .taskComplete,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .working)
    }

    @Test(arguments: [NotificationType.error, .attentionNeeded, .focusRequest])
    func highSeverityBadgeWinsOverWorkingIcon(notification: NotificationType) {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: notification,
            isSuspended: false,
            hasPRStatus: true
        )
        #expect(result == .notificationBadge(notification))
    }

    @Test(arguments: [NotificationType.taskComplete, .responseComplete])
    func lowSeverityBadgeYieldsToWorkingIcon(notification: NotificationType) {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: notification,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == .working)
    }

    @Test func pendingWinsOverHighSeverityBadge() {
        let result = RowStatusIndicator.resolve(
            isPending: true,
            isWorking: false,
            notification: .error,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == .pending)
    }

    @Test func workingIconHidesPRStatus() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            notification: nil,
            isSuspended: false,
            hasPRStatus: true
        )
        #expect(result == .working)
    }

    @Test func notificationWinsOverSuspendedAndPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: .responseComplete,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .notificationBadge(.responseComplete))
    }

    @Test func suspendedWinsOverPR() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .suspended)
    }

    @Test func prStatusAlone() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: false,
            hasPRStatus: true
        )
        #expect(result == .prStatus)
    }

    @Test func nothingSetReturnsNil() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            notification: nil,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == nil)
    }

    // MARK: - waitingForUser priority

    @Test func waitingForUserOutranksWorking() {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: true,
            isWaitingForUser: true,
            notification: nil,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == .waitingForUser)
    }

    @Test func pendingWinsOverWaitingForUser() {
        let result = RowStatusIndicator.resolve(
            isPending: true,
            isWorking: false,
            isWaitingForUser: true,
            notification: nil,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == .pending)
    }

    @Test(arguments: [NotificationType.error, .attentionNeeded, .focusRequest])
    func highSeverityBadgeWinsOverWaitingForUser(notification: NotificationType) {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            isWaitingForUser: true,
            notification: notification,
            isSuspended: false,
            hasPRStatus: false
        )
        #expect(result == .notificationBadge(notification))
    }

    @Test(arguments: [NotificationType.taskComplete, .responseComplete])
    func waitingForUserWinsOverLowSeverityBadge(notification: NotificationType) {
        let result = RowStatusIndicator.resolve(
            isPending: false,
            isWorking: false,
            isWaitingForUser: true,
            notification: notification,
            isSuspended: true,
            hasPRStatus: true
        )
        #expect(result == .waitingForUser)
    }
}
