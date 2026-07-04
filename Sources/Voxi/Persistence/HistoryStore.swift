import Foundation
import GRDB

/// Builds safe FTS5 MATCH patterns from free-form user input.
enum FTSQuery {
    /// Each whitespace-separated token becomes a quoted string (implicit AND),
    /// so FTS5 operators like OR/NOT/NEAR and column filters are matched as
    /// literal words instead of being interpreted. Returns nil when the input
    /// contains nothing searchable.
    static func sanitizedMatchPattern(_ raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }
}

/// Dictation history: every completed dictation, searchable via FTS5.
struct HistoryStore: Sendable {
    let database: AppDatabase

    func save(_ entry: HistoryEntry) async throws {
        try await database.dbQueue.write { db in
            try entry.save(db)
        }
    }

    /// Newest first. `offset` supports paging in the Hub.
    func recent(limit: Int, offset: Int = 0) async throws -> [HistoryEntry] {
        try await database.dbQueue.read { db in
            try HistoryEntry
                .order(HistoryEntry.Columns.createdAt.desc, Column.rowID.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Full-text search over rawTranscript + finalText, newest first.
    /// Empty or unsearchable queries return [].
    func search(query: String) async throws -> [HistoryEntry] {
        guard let pattern = FTSQuery.sanitizedMatchPattern(query) else { return [] }
        return try await database.dbQueue.read { db in
            try HistoryEntry.fetchAll(
                db,
                sql: """
                    SELECT history.*
                    FROM history
                    JOIN history_ft ON history_ft.rowid = history.rowid
                    WHERE history_ft MATCH ?
                    ORDER BY history.createdAt DESC, history.rowid DESC
                    """,
                arguments: [pattern]
            )
        }
    }

    func delete(id: UUID) async throws {
        _ = try await database.dbQueue.write { db in
            try HistoryEntry.deleteOne(db, key: id.uuidString.lowercased())
        }
    }

    func deleteAll() async throws {
        _ = try await database.dbQueue.write { db in
            try HistoryEntry.deleteAll(db)
        }
    }

    /// Emits the newest `limit` entries now and after every history change.
    func observeRecent(limit: Int = 200) -> AsyncValueObservation<[HistoryEntry]> {
        ValueObservation
            .tracking { db in
                try HistoryEntry
                    .order(HistoryEntry.Columns.createdAt.desc, Column.rowID.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            .values(in: database.dbQueue)
    }
}
