import Foundation

/// Errors raised by the command-queue layer (on top of `PersistenceError`
/// and `DispatcherError`).
enum QueueError: Error, LocalizedError, Equatable {
    /// Card content is only editable while the card is still queued.
    case cardNotEditable(CardStatus)
    /// A dispatch is already in flight for this card.
    case alreadyDispatching(UUID)
    /// Follow-up requested on a card whose run recorded no session id.
    case noSessionToResume(UUID)

    var errorDescription: String? {
        switch self {
        case .cardNotEditable(let status):
            "Card is \(status.rawValue) and can no longer be edited."
        case .alreadyDispatching(let id):
            "Card \(id.uuidString) is already being dispatched."
        case .noSessionToResume:
            "This card's run did not record a session to resume."
        }
    }
}

/// Encoding/decoding of the dispatcher-parameter JSON stored on each card.
/// The schema is dispatcher-defined; the queue only ever sees a flat
/// string-to-string object.
enum QueueParams {
    /// Well-known param key used by dispatchers that run in a directory.
    static let workingDirectoryKey = "workingDirectory"
    /// Well-known param key: backend session a follow-up card resumes.
    static let resumeSessionIDKey = "resumeSessionID"

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
    /// Dispatch is only offered for queued cards with a non-blank prompt
    /// whose required parameters are all present and non-blank. (The prompt
    /// rule also keeps a fresh follow-up card parked until it's written.)
    static func canDispatch(
        status: CardStatus,
        prompt: String,
        params: [String: String],
        specs: [DispatcherParamSpec]
    ) -> Bool {
        guard status == .queued else { return false }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return specs.allSatisfy { spec in
            guard spec.required else { return true }
            let value = params[spec.id] ?? ""
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// IDs a "Run All" should dispatch: queued cards that pass the dispatch
    /// gate, oldest first. Cards that fail the gate (blank prompt, missing
    /// params, unknown dispatcher) are skipped — left queued, never failed.
    static func drainOrder(
        cards: [ActionCard],
        specsFor: (String) -> [DispatcherParamSpec]?
    ) -> [UUID] {
        cards
            .filter { $0.status == .queued }
            .sorted { $0.createdAt < $1.createdAt }
            .filter { card in
                guard let specs = specsFor(card.dispatcherID) else { return false }
                let params = (try? QueueParams.decode(card.paramsJSON)) ?? [:]
                return canDispatch(status: card.status, prompt: card.prompt, params: params, specs: specs)
            }
            .map(\.id)
    }

    /// Digit-filter + clamp for integer param fields: non-numeric input
    /// becomes empty (falls back to the spec default at dispatch), numbers
    /// clamp into the spec's range.
    static func sanitizedIntegerInput(_ raw: String, range: ClosedRange<Int>) -> String {
        let digits = raw.filter(\.isNumber)
        guard let value = Int(digits) else { return "" }
        return String(min(max(value, range.lowerBound), range.upperBound))
    }

    /// Which log a card view should show: while in flight, the runner's
    /// immediate live tail beats the flush-throttled persisted log; once
    /// terminal (or still queued) the persisted log is the complete record.
    /// Single source of truth for CardDetailView and the full log viewer.
    static func displayLog(status: CardStatus, liveTail: String?, persistedLog: String) -> String {
        if status == .dispatched || status == .running, let liveTail {
            return liveTail
        }
        return persistedLog
    }

    /// Badge text for the raw-transcript disclosure — the spec requires the
    /// card to say whether an LLM produced the prompt.
    static func refinementBadge(refinedByLLM: Bool) -> String {
        refinedByLLM
            ? "Refined by LLM"
            : "Cleaned transcript used verbatim — no LLM configured"
    }
}
