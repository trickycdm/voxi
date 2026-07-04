import Foundation

/// Lifecycle of an action card. Persisted as the raw string value.
enum CardStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case dispatched
    case running
    case succeeded
    case failed

    var isTerminal: Bool { self == .succeeded || self == .failed }

    /// Legal transitions; anything else is a programming error worth surfacing.
    func canTransition(to next: CardStatus) -> Bool {
        switch (self, next) {
        case (.queued, .dispatched),
             (.dispatched, .running),
             (.dispatched, .failed),   // spawn failure before any output
             (.running, .succeeded),
             (.running, .failed),
             (.failed, .queued):       // re-queue for retry after edit
            true
        default:
            false
        }
    }
}

/// A dictated task awaiting (or undergoing) execution. Persisted in GRDB;
/// cards survive app restarts. A card that was mid-run when the app died is
/// reconciled to `.failed` on next launch.
struct ActionCard: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var title: String
    var summary: String
    /// Editable before dispatch; what actually gets sent to the dispatcher.
    var prompt: String
    var rawTranscript: String
    var refinedByLLM: Bool
    var status: CardStatus
    var dispatcherID: String
    /// Dispatcher parameters, serialized as JSON (schema is dispatcher-defined).
    var paramsJSON: String
    var log: String
    var exitCode: Int?
    var dispatchedAt: Date?
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        summary: String,
        prompt: String,
        rawTranscript: String,
        refinedByLLM: Bool,
        dispatcherID: String,
        paramsJSON: String = "{}"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.summary = summary
        self.prompt = prompt
        self.rawTranscript = rawTranscript
        self.refinedByLLM = refinedByLLM
        self.status = .queued
        self.dispatcherID = dispatcherID
        self.paramsJSON = paramsJSON
        self.log = ""
        self.exitCode = nil
    }
}
