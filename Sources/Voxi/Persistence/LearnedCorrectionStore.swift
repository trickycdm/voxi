import Foundation
import GRDB

/// Log of wrong→right pairs picked up by post-insert correction learning.
/// Pairs are unique case-insensitively (COLLATE NOCASE columns under the
/// unique key); re-learning an existing pair just bumps `learnedAt`.
struct LearnedCorrectionStore: Sendable {
    let database: AppDatabase

    /// Inserts the pair, or — when it already exists under any casing —
    /// refreshes that row's `learnedAt` while preserving its identity.
    /// Returns the stored correction.
    @discardableResult
    func upsert(_ correction: LearnedCorrection) async throws -> LearnedCorrection {
        try await database.dbQueue.write { db in
            // Both columns carry COLLATE NOCASE, so this match is case-insensitive.
            if var existing = try LearnedCorrection
                .filter(LearnedCorrection.Columns.wrong == correction.wrong)
                .filter(LearnedCorrection.Columns.right == correction.right)
                .fetchOne(db)
            {
                existing.learnedAt = correction.learnedAt
                try existing.update(db)
                return existing
            }
            try correction.insert(db)
            return correction
        }
    }

    /// All learned pairs, newest first (for the Hub's learned list).
    func all() async throws -> [LearnedCorrection] {
        try await database.dbQueue.read { db in
            try LearnedCorrection
                .order(LearnedCorrection.Columns.learnedAt.desc)
                .fetchAll(db)
        }
    }

    func delete(id: UUID) async throws {
        _ = try await database.dbQueue.write { db in
            try LearnedCorrection.deleteOne(db, key: id.uuidString.lowercased())
        }
    }

    /// Removes every learned pair whose corrected term matches `right` —
    /// used when the dictionary entry itself is deleted, so the learned list
    /// never shows pairs that are no longer enforced.
    func deleteAll(right: String) async throws {
        _ = try await database.dbQueue.write { db in
            try LearnedCorrection
                .filter(LearnedCorrection.Columns.right == right)
                .deleteAll(db)
        }
    }
}
