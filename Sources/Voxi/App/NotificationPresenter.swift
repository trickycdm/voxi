import Foundation
import UserNotifications

/// Formats queue notifications. Pure so the formatting is unit-testable
/// without touching UserNotifications.
enum QueueNotificationContent {
    static let bodyLimit = 180

    private static let runPrefix = "voxi.run."
    private static let queuedPrefix = "voxi.queued."

    static func make(cardTitle: String, success: Bool, resultText: String?) -> (title: String, body: String) {
        let title = success ? "✓ \(cardTitle)" : "✗ \(cardTitle) failed"
        var body = resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.count > bodyLimit {
            body = String(body.prefix(bodyLimit - 1)) + "…"
        }
        return (title, body)
    }

    static func makeQueued(cardTitle: String) -> (title: String, body: String) {
        ("Queued: \(cardTitle)", "Review and dispatch it from the Hub.")
    }

    static func runIdentifier(cardID: UUID) -> String {
        runPrefix + cardID.uuidString
    }

    static func queuedIdentifier(cardID: UUID) -> String {
        queuedPrefix + cardID.uuidString
    }

    /// Card behind a notification identifier (either kind); nil for anything
    /// that isn't a well-formed Voxi queue identifier.
    static func cardID(fromIdentifier identifier: String) -> UUID? {
        for prefix in [runPrefix, queuedPrefix] where identifier.hasPrefix(prefix) {
            return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
        }
        return nil
    }
}

/// Posts system notifications when cards are queued and when runs finish, and
/// routes banner taps back into the app (deep-link to the Hub's queue pane).
///
/// Authorization is requested just-in-time on the first queued card — the
/// moment a task enters the queue is when "notify me when tasks finish"
/// makes sense — never at launch. Denial is fine: the pill notice is the
/// always-available fallback. Construction is inert; nothing touches
/// UNUserNotificationCenter until `activate()` (never called in CLI mode).
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked when the user taps a queue notification, with the card id
    /// parsed from the notification's identifier (nil if unparseable).
    var onOpen: ((UUID?) -> Void)?

    private var authorizationRequested = false
    private var authorizationResolved = false
    /// Work deferred until the first authorization request resolves — posting
    /// before then would race the permission prompt and be silently dropped.
    private var pendingAfterAuthorization: [@MainActor @Sendable () -> Void] = []

    /// Install as the notification-center delegate (GUI startup only).
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for permission once, contextually; repeat calls are no-ops (the
    /// system ignores repeat requests after the user has decided). `then`
    /// runs on MainActor once authorization has resolved — immediately if it
    /// already has, else from the completion (granted or not: posting while
    /// denied is a harmless no-op, and the pill notice remains the fallback).
    func requestAuthorizationIfNeeded(then: (@MainActor @Sendable () -> Void)? = nil) {
        if authorizationResolved {
            then?()
            return
        }
        if let then {
            pendingAfterAuthorization.append(then)
        }
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            voxiLog.info("notifications: authorization \(granted ? "granted" : "denied", privacy: .public)")
            Task { @MainActor in
                self.authorizationResolved = true
                let pending = self.pendingAfterAuthorization
                self.pendingAfterAuthorization = []
                for work in pending { work() }
            }
        }
    }

    func postCardQueued(cardID: UUID, cardTitle: String) {
        let (title, body) = QueueNotificationContent.makeQueued(cardTitle: cardTitle)
        post(identifier: QueueNotificationContent.queuedIdentifier(cardID: cardID), title: title, body: body)
    }

    func postRunFinished(cardID: UUID, cardTitle: String, success: Bool, resultText: String?) {
        let (title, body) = QueueNotificationContent.make(
            cardTitle: cardTitle, success: success, resultText: resultText)
        post(identifier: QueueNotificationContent.runIdentifier(cardID: cardID), title: title, body: body)
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                voxiLog.warning("notifications: post failed (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Delegate methods are nonisolated (the center calls them on its own
    // queue, and their parameters are non-Sendable so they must not cross
    // into MainActor code) — only Sendable values hop to main.

    /// Voxi is an LSUIElement accessory app, but show banners even if we're
    /// somehow frontmost — the Hub being open shouldn't hide results.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Parse before the hop: the response is non-Sendable, the UUID is.
        let cardID = QueueNotificationContent.cardID(
            fromIdentifier: response.notification.request.identifier)
        Task { @MainActor in self.onOpen?(cardID) }
        completionHandler()
    }
}
