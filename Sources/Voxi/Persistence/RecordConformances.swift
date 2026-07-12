import Foundation
import GRDB

// GRDB conformances for the frozen record structs. Hand-written (rather than
// Codable-derived) so the storage format is explicit: UUIDs persist as
// lowercased strings, `variants` as JSON text, `status` as its raw value.

extension HistoryEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "history"

    enum Columns {
        static let uuid = Column("uuid")
        static let createdAt = Column("createdAt")
    }

    init(row: Row) throws {
        self.init(
            id: row["uuid"],
            createdAt: row["createdAt"],
            rawTranscript: row["rawTranscript"],
            finalText: row["finalText"],
            engineID: row["engineID"],
            modelID: row["modelID"],
            refinerID: row["refinerID"],
            targetAppBundleID: row["targetAppBundleID"],
            durationSeconds: row["durationSeconds"]
        )
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["uuid"] = id.uuidString.lowercased()
        container["createdAt"] = createdAt
        container["rawTranscript"] = rawTranscript
        container["finalText"] = finalText
        container["engineID"] = engineID
        container["modelID"] = modelID
        container["refinerID"] = refinerID
        container["targetAppBundleID"] = targetAppBundleID
        container["durationSeconds"] = durationSeconds
    }
}

extension DictionaryEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "dictionaryEntry"

    enum Columns {
        static let term = Column("term")
    }

    init(row: Row) throws {
        let variantsJSON: String = row["variants"]
        let variants: [String]
        do {
            variants = try JSONDecoder().decode([String].self, from: Data(variantsJSON.utf8))
        } catch {
            throw PersistenceError.corruptRow("dictionaryEntry.variants is not a JSON string array: \(variantsJSON)")
        }
        self.init(
            id: row["uuid"],
            term: row["term"],
            variants: variants,
            createdAt: row["createdAt"]
        )
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["uuid"] = id.uuidString.lowercased()
        container["term"] = term
        container["variants"] = String(decoding: try JSONEncoder().encode(variants), as: UTF8.self)
        container["createdAt"] = createdAt
    }
}

extension ActionCard: FetchableRecord, PersistableRecord {
    static let databaseTableName = "actionCard"

    enum Columns {
        static let uuid = Column("uuid")
        static let createdAt = Column("createdAt")
        static let status = Column("status")
    }

    init(row: Row) throws {
        var card = ActionCard(
            id: row["uuid"],
            createdAt: row["createdAt"],
            title: row["title"],
            summary: row["summary"],
            prompt: row["prompt"],
            rawTranscript: row["rawTranscript"],
            refinedByLLM: row["refinedByLLM"],
            dispatcherID: row["dispatcherID"],
            paramsJSON: row["paramsJSON"]
        )
        let statusRaw: String = row["status"]
        guard let status = CardStatus(rawValue: statusRaw) else {
            throw PersistenceError.corruptRow("actionCard.status has unknown value: \(statusRaw)")
        }
        card.status = status
        card.log = row["log"]
        card.exitCode = row["exitCode"]
        card.dispatchedAt = row["dispatchedAt"]
        card.finishedAt = row["finishedAt"]
        card.sessionID = row["sessionID"]
        self = card
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["uuid"] = id.uuidString.lowercased()
        container["createdAt"] = createdAt
        container["title"] = title
        container["summary"] = summary
        container["prompt"] = prompt
        container["rawTranscript"] = rawTranscript
        container["refinedByLLM"] = refinedByLLM
        container["status"] = status.rawValue
        container["dispatcherID"] = dispatcherID
        container["paramsJSON"] = paramsJSON
        container["log"] = log
        container["exitCode"] = exitCode
        container["dispatchedAt"] = dispatchedAt
        container["finishedAt"] = finishedAt
        container["sessionID"] = sessionID
    }
}
