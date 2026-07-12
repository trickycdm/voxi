import Foundation
import GRDB

/// Action-card queue persistence. All status changes go through helpers that
/// validate against `CardStatus.canTransition` — an illegal transition throws
/// rather than corrupting the lifecycle.
struct CardStore: Sendable {
    let database: AppDatabase

    func insert(_ card: ActionCard) async throws {
        try await database.dbQueue.write { db in
            try card.insert(db)
        }
    }

    func fetch(id: UUID) async throws -> ActionCard? {
        try await database.dbQueue.read { db in
            try ActionCard.fetchOne(db, key: id.uuidString.lowercased())
        }
    }

    func allNewestFirst() async throws -> [ActionCard] {
        try await database.dbQueue.read { db in
            try ActionCard
                .order(ActionCard.Columns.createdAt.desc, Column.rowID.desc)
                .fetchAll(db)
        }
    }

    /// Validated status transition. Also maintains the lifecycle timestamps:
    /// → dispatched stamps dispatchedAt; → succeeded/failed stamps finishedAt;
    /// → queued (retry after failure) clears the previous run's outputs.
    func setStatus(id: UUID, to next: CardStatus) async throws {
        try await database.dbQueue.write { db in
            var card = try Self.existing(db, id: id)
            guard card.status.canTransition(to: next) else {
                throw PersistenceError.illegalTransition(from: card.status, to: next)
            }
            card.status = next
            switch next {
            case .dispatched:
                card.dispatchedAt = Date()
            case .succeeded, .failed:
                card.finishedAt = Date()
            case .queued:
                card.dispatchedAt = nil
                card.finishedAt = nil
                card.exitCode = nil
                card.log = ""
                card.sessionID = nil
            case .running:
                break
            }
            try card.update(db)
        }
    }

    /// Terminal transition driven by the dispatcher's exit code.
    func setResult(id: UUID, exitCode: Int) async throws {
        try await database.dbQueue.write { db in
            var card = try Self.existing(db, id: id)
            let next: CardStatus = exitCode == 0 ? .succeeded : .failed
            guard card.status.canTransition(to: next) else {
                throw PersistenceError.illegalTransition(from: card.status, to: next)
            }
            card.status = next
            card.exitCode = exitCode
            card.finishedAt = Date()
            try card.update(db)
        }
    }

    /// Appends a log chunk in a single UPDATE — no read-modify-write of the
    /// whole (potentially large) log in Swift.
    func appendLog(id: UUID, chunk: String) async throws {
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE actionCard SET log = log || ? WHERE uuid = ?",
                arguments: [chunk, id.uuidString.lowercased()]
            )
            guard db.changesCount > 0 else {
                throw PersistenceError.notFound(id)
            }
        }
    }

    /// Launch-time reconciliation: any card that was mid-flight when the app
    /// died is marked failed with an explanatory log note. Returns the number
    /// of cards reconciled.
    @discardableResult
    func reconcileInterrupted() async throws -> Int {
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE actionCard
                    SET status = ?,
                        finishedAt = ?,
                        log = log || ?
                    WHERE status IN (?, ?)
                    """,
                arguments: [
                    CardStatus.failed.rawValue,
                    Date(),
                    "\n[voxi] Voxi quit while this card was in flight; marked as failed.\n",
                    CardStatus.dispatched.rawValue,
                    CardStatus.running.rawValue,
                ]
            )
            return db.changesCount
        }
    }

    func delete(id: UUID) async throws {
        _ = try await database.dbQueue.write { db in
            try ActionCard.deleteOne(db, key: id.uuidString.lowercased())
        }
    }

    /// Emits all cards (newest first) now and after every card change.
    func observeAll() -> AsyncValueObservation<[ActionCard]> {
        ValueObservation
            .tracking { db in
                try ActionCard
                    .order(ActionCard.Columns.createdAt.desc, Column.rowID.desc)
                    .fetchAll(db)
            }
            .values(in: database.dbQueue)
    }

    private static func existing(_ db: Database, id: UUID) throws -> ActionCard {
        guard let card = try ActionCard.fetchOne(db, key: id.uuidString.lowercased()) else {
            throw PersistenceError.notFound(id)
        }
        return card
    }
}
