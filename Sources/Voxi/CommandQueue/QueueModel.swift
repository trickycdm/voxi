import Foundation
import Observation

/// Owns the card list for the queue UI: loads newest-first from CardStore
/// and stays live via the store's value observation. All mutations write
/// through the store; observation echoes them back into `cards`.
@MainActor
@Observable
final class QueueModel {
    private(set) var cards: [ActionCard] = []

    @ObservationIgnored private let store: CardStore
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(store: CardStore) {
        self.store = store
    }

    deinit {
        observationTask?.cancel()
    }

    /// One-shot load, for callers (and tests) that don't observe.
    func load() async throws {
        cards = try await store.allNewestFirst()
    }

    /// Starts the live observation. The observation emits the current cards
    /// immediately, so a separate `load()` is unnecessary once this runs.
    func startObserving() {
        guard observationTask == nil else { return }
        observationTask = Task { [store] in
            do {
                for try await cards in store.observeAll() {
                    self.cards = cards
                }
            } catch is CancellationError {
                // normal teardown
            } catch {
                voxiLog.error("queue: card observation failed (\(error.localizedDescription, privacy: .public))")
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Persists a refined command-mode dictation as a queued card.
    /// `rawTranscript` travels beside the draft because `CardDraft` (frozen
    /// contract) carries only the refined fields.
    @discardableResult
    func addCard(
        draft: CardDraft,
        rawTranscript: String,
        dispatcherID: String,
        params: [String: String] = [:]
    ) async throws -> ActionCard {
        let card = ActionCard(
            title: draft.title,
            summary: draft.summary,
            prompt: draft.prompt,
            rawTranscript: rawTranscript,
            refinedByLLM: draft.refinedByLLM,
            dispatcherID: dispatcherID,
            paramsJSON: try QueueParams.encode(params)
        )
        try await store.insert(card)
        return card
    }

    func updatePrompt(id: UUID, to prompt: String) async throws {
        try await store.updateEditable(id: id, prompt: prompt)
    }

    func updateTitle(id: UUID, to title: String) async throws {
        try await store.updateEditable(id: id, title: title)
    }

    func updateParams(id: UUID, to params: [String: String]) async throws {
        try await store.updateEditable(id: id, paramsJSON: try QueueParams.encode(params))
    }

    func delete(id: UUID) async throws {
        try await store.delete(id: id)
    }

    /// Re-queues a failed card (validated failed → queued transition; the
    /// store clears the previous run's log, exit code, and timestamps).
    func retry(id: UUID) async throws {
        try await store.setStatus(id: id, to: .queued)
    }

    /// Creates a new queued card that resumes the given card's backend
    /// session: same working directory and params, empty prompt (the user
    /// types the follow-up), `resumeSessionID` set so the dispatcher appends
    /// `--resume`. The empty prompt keeps it un-dispatchable until edited.
    @discardableResult
    func followUp(from card: ActionCard) async throws -> ActionCard {
        guard let sessionID = card.sessionID, !sessionID.isEmpty else {
            throw QueueError.noSessionToResume(card.id)
        }
        var params = (try? QueueParams.decode(card.paramsJSON)) ?? [:]
        params[QueueParams.resumeSessionIDKey] = sessionID
        let followUp = ActionCard(
            title: "Follow-up: \(card.title)",
            summary: "Continues the session from “\(card.title)”.",
            prompt: "",
            rawTranscript: "",
            refinedByLLM: false,
            dispatcherID: card.dispatcherID,
            paramsJSON: try QueueParams.encode(params)
        )
        try await store.insert(followUp)
        return followUp
    }
}
