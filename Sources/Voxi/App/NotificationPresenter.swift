import Foundation
import UserNotifications

/// Formats queue notifications. Pure so the formatting is unit-testable
/// without touching UserNotifications.
enum QueueNotificationContent {
    static let bodyLimit = 180

    static func make(cardTitle: String, success: Bool, resultText: String?) -> (title: String, body: String) {
        let title = success ? "✓ \(cardTitle)" : "✗ \(cardTitle) failed"
        var body = resultText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.count > bodyLimit {
            body = String(body.prefix(bodyLimit - 1)) + "…"
        }
        return (title, body)
    }
}

/// Posts system notifications for queue run completions and routes banner
/// taps back into the app (open the queue window).
///
/// Authorization is requested just-in-time on the first queued card — the
/// moment a task enters the queue is when "notify me when tasks finish"
/// makes sense — never at launch. Denial is fine: the pill notice is the
/// always-available fallback. Construction is inert; nothing touches
/// UNUserNotificationCenter until `activate()` (never called in CLI mode).
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked when the user taps a queue notification.
    var onOpen: (() -> Void)?

    private var authorizationRequested = false

    /// Install as the notification-center delegate (GUI startup only).
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for permission once, contextually. No-op after the first call;
    /// the system ignores repeat requests after the user has decided.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            voxiLog.info("notifications: authorization \(granted ? "granted" : "denied", privacy: .public)")
        }
    }

    func postRunFinished(cardID: UUID, cardTitle: String, success: Bool, resultText: String?) {
        let (title, body) = QueueNotificationContent.make(
            cardTitle: cardTitle, success: success, resultText: resultText)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "voxi.run.\(cardID.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                voxiLog.warning("notifications: post failed (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Delegate methods are nonisolated (the center calls them on its own
    // queue, and their parameters are non-Sendable so they must not cross
    // into MainActor code) — only the parameter-free hop goes to main.

    /// Voxi is an LSUIElement accessory app, but show banners even if we're
    /// somehow frontmost — the queue window being open shouldn't hide results.
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
        Task { @MainActor in self.onOpen?() }
        completionHandler()
    }
}
