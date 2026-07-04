import Foundation
import GRDB

/// Errors thrown by the persistence layer.
enum PersistenceError: Error, Equatable {
    case notFound(UUID)
    case illegalTransition(from: CardStatus, to: CardStatus)
    /// A stored row contains data the app can no longer interpret.
    case corruptRow(String)
}

/// Owns the single SQLite connection and its schema. All persisted state
/// (history, dictionary, action cards) lives in this one database; settings
/// stay in UserDefaults.
final class AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    /// Opens (and migrates) the on-disk database at `VoxiPaths.databaseURL`.
    convenience init() throws {
        try self.init(queue: DatabaseQueue(path: VoxiPaths.databaseURL.path))
    }

    /// `inMemory: true` gives tests a private, empty, fully migrated database.
    convenience init(inMemory: Bool) throws {
        if inMemory {
            try self.init(queue: DatabaseQueue())
        } else {
            try self.init()
        }
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "history") { t in
                t.primaryKey("uuid", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("rawTranscript", .text).notNull()
                t.column("finalText", .text).notNull()
                t.column("engineID", .text).notNull()
                t.column("modelID", .text).notNull()
                t.column("refinerID", .text)
                t.column("targetAppBundleID", .text)
                t.column("durationSeconds", .double).notNull()
            }

            // External-content FTS5 index over the searchable text columns.
            // synchronize(withTable:) installs the insert/update/delete triggers
            // that keep the index in lockstep with `history`.
            try db.create(virtualTable: "history_ft", using: FTS5()) { t in
                t.synchronize(withTable: "history")
                t.column("rawTranscript")
                t.column("finalText")
            }

            try db.create(table: "dictionaryEntry") { t in
                t.primaryKey("uuid", .text)
                t.column("term", .text).notNull().collate(.nocase).unique()
                t.column("variants", .text).notNull() // JSON array of strings
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "actionCard") { t in
                t.primaryKey("uuid", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("rawTranscript", .text).notNull()
                t.column("refinedByLLM", .boolean).notNull()
                t.column("status", .text).notNull()
                t.column("dispatcherID", .text).notNull()
                t.column("paramsJSON", .text).notNull()
                t.column("log", .text).notNull()
                t.column("exitCode", .integer)
                t.column("dispatchedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
        }

        return migrator
    }
}
