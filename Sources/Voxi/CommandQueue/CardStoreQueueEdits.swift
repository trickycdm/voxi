import Foundation
import GRDB

// Queue-side persistence helpers that CardStore doesn't provide.
// Kept in the CommandQueue module (CardStore itself belongs to Persistence);
// candidates for folding into CardStore proper at integration time.

extension CardStore {
    /// Edits to card content are only legal before dispatch. Passing `nil`
    /// leaves a field untouched.
    func updateEditable(
        id: UUID,
        title: String? = nil,
        summary: String? = nil,
        prompt: String? = nil,
        paramsJSON: String? = nil
    ) async throws {
        try await database.dbQueue.write { db in
            guard var card = try ActionCard.fetchOne(db, key: id.uuidString.lowercased()) else {
                throw PersistenceError.notFound(id)
            }
            guard card.status == .queued else {
                throw QueueError.cardNotEditable(card.status)
            }
            if let title { card.title = title }
            if let summary { card.summary = summary }
            if let prompt { card.prompt = prompt }
            if let paramsJSON { card.paramsJSON = paramsJSON }
            try card.update(db)
        }
    }

    /// Terminal transition where success and exit code are decided
    /// independently (unlike `setResult`, which infers status from the exit
    /// code — a dispatcher can fail with exit 0, e.g. an API error result,
    /// or finish with no exit code at all, e.g. cancellation).
    func finish(id: UUID, success: Bool, exitCode: Int?, sessionID: String? = nil) async throws {
        try await database.dbQueue.write { db in
            guard var card = try ActionCard.fetchOne(db, key: id.uuidString.lowercased()) else {
                throw PersistenceError.notFound(id)
            }
            let next: CardStatus = success ? .succeeded : .failed
            guard card.status.canTransition(to: next) else {
                throw PersistenceError.illegalTransition(from: card.status, to: next)
            }
            card.status = next
            card.exitCode = exitCode
            card.finishedAt = Date()
            // Written atomically with the terminal state; nil (cancel/throw
            // paths) leaves any previously stored session id untouched.
            if let sessionID { card.sessionID = sessionID }
            try card.update(db)
        }
    }
}
