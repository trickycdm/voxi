import Foundation
import Testing
@testable import Voxi

@Suite("QueueNotificationContent")
struct NotificationContentTests {
    @Test func successTitleAndBody() {
        let (title, body) = QueueNotificationContent.make(
            cardTitle: "Fix the tests", success: true, resultText: "3 files changed.")
        #expect(title == "✓ Fix the tests")
        #expect(body == "3 files changed.")
    }

    @Test func failureTitle() {
        let (title, _) = QueueNotificationContent.make(
            cardTitle: "Fix the tests", success: false, resultText: nil)
        #expect(title == "✗ Fix the tests failed")
    }

    @Test func bodyIsTrimmedAndNilBecomesEmpty() {
        let (_, trimmed) = QueueNotificationContent.make(
            cardTitle: "T", success: true, resultText: "  done \n")
        #expect(trimmed == "done")
        let (_, empty) = QueueNotificationContent.make(
            cardTitle: "T", success: true, resultText: nil)
        #expect(empty.isEmpty)
    }

    @Test func longBodyIsTruncatedWithEllipsis() {
        let long = String(repeating: "x", count: 400)
        let (_, body) = QueueNotificationContent.make(
            cardTitle: "T", success: true, resultText: long)
        #expect(body.count == QueueNotificationContent.bodyLimit)
        #expect(body.hasSuffix("…"))
    }

    @Test func queuedTitleAndBody() {
        let (title, body) = QueueNotificationContent.makeQueued(cardTitle: "Fix the tests")
        #expect(title == "Queued: Fix the tests")
        #expect(!body.isEmpty)
    }

    @Test func identifiersRoundTripToCardID() {
        let id = UUID()
        #expect(QueueNotificationContent.cardID(
            fromIdentifier: QueueNotificationContent.runIdentifier(cardID: id)) == id)
        #expect(QueueNotificationContent.cardID(
            fromIdentifier: QueueNotificationContent.queuedIdentifier(cardID: id)) == id)
    }

    @Test func malformedIdentifiersParseToNil() {
        #expect(QueueNotificationContent.cardID(fromIdentifier: "voxi.run.not-a-uuid") == nil)
        #expect(QueueNotificationContent.cardID(fromIdentifier: "other.\(UUID().uuidString)") == nil)
        #expect(QueueNotificationContent.cardID(fromIdentifier: "") == nil)
    }
}
