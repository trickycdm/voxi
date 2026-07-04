import Foundation

/// Errors raised by the command-queue layer (on top of `PersistenceError`
/// and `DispatcherError`).
enum QueueError: Error, LocalizedError, Equatable {
    /// Card content is only editable while the card is still queued.
    case cardNotEditable(CardStatus)
    /// A dispatch is already in flight for this card.
    case alreadyDispatching(UUID)

    var errorDescription: String? {
        switch self {
        case .cardNotEditable(let status):
            "Card is \(status.rawValue) and can no longer be edited."
        case .alreadyDispatching(let id):
            "Card \(id.uuidString) is already being dispatched."
        }
    }
}

/// Encoding/decoding of the dispatcher-parameter JSON stored on each card.
/// The schema is dispatcher-defined; the queue only ever sees a flat
/// string-to-string object.
enum QueueParams {
    /// Well-known param key used by dispatchers that run in a directory.
    static let workingDirectoryKey = "workingDirectory"

    static func encode(_ params: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(params), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }
}

/// Recently used working directories, shared across cards.
/// Stored as a string array under the `voxi.recentDirs` defaults key.
enum RecentDirs {
    static let defaultsKey = "voxi.recentDirs"
    static let maxCount = 8

    /// Pure list update: dedupes, puts `path` first, caps the length.
    static func inserting(_ path: String, into list: [String], max: Int = maxCount) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(list.prefix(max)) }
        var updated = list.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        return Array(updated.prefix(max))
    }

    static func list(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func remember(_ path: String, in defaults: UserDefaults = .standard) {
        defaults.set(inserting(path, into: list(from: defaults)), forKey: defaultsKey)
    }
}

/// Pure UI-decision helpers, kept out of the views so they're unit-testable.
enum QueueLogic {
    /// Dispatch is only offered for queued cards whose required parameters
    /// are all present and non-blank.
    static func canDispatch(
        status: CardStatus,
        params: [String: String],
        specs: [DispatcherParamSpec]
    ) -> Bool {
        guard status == .queued else { return false }
        return specs.allSatisfy { spec in
            guard spec.required else { return true }
            let value = params[spec.id] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Badge text for the raw-transcript disclosure — the spec requires the
    /// card to say whether an LLM produced the prompt.
    static func refinementBadge(refinedByLLM: Bool) -> String {
        refinedByLLM
            ? "Refined by LLM"
            : "Cleaned transcript used verbatim — no LLM configured"
    }
}
