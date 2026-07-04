import Foundation
import GRDB

/// Personal dictionary of names/acronyms/jargon. Terms are unique
/// case-insensitively (enforced by the COLLATE NOCASE unique column).
struct DictionaryStore: Sendable {
    let database: AppDatabase

    /// Inserts the entry, or — when a term already exists under any casing —
    /// updates that row in place (adopting the new casing and variants) while
    /// preserving its identity. Returns the stored entry.
    @discardableResult
    func upsert(_ entry: DictionaryEntry) async throws -> DictionaryEntry {
        try await database.dbQueue.write { db in
            // `term` carries COLLATE NOCASE, so this comparison is case-insensitive.
            if var existing = try DictionaryEntry
                .filter(DictionaryEntry.Columns.term == entry.term)
                .fetchOne(db)
            {
                existing.term = entry.term
                existing.variants = entry.variants
                try existing.update(db)
                return existing
            }
            try entry.insert(db)
            return entry
        }
    }

    /// All entries, sorted by term (case-insensitive).
    func all() async throws -> [DictionaryEntry] {
        try await database.dbQueue.read { db in
            try DictionaryEntry
                .order(DictionaryEntry.Columns.term.collating(.nocase).asc)
                .fetchAll(db)
        }
    }

    /// Just the terms, for feeding TranscriptionHints / RefinementContext.
    func allTerms() async throws -> [String] {
        try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT term FROM dictionaryEntry ORDER BY term COLLATE NOCASE"
            )
        }
    }

    func delete(id: UUID) async throws {
        _ = try await database.dbQueue.write { db in
            try DictionaryEntry.deleteOne(db, key: id.uuidString.lowercased())
        }
    }
}
