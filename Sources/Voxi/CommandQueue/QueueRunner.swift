import Foundation
import Observation

/// Looks up a dispatcher by id. The real registry (Dispatchers module) is
/// adapted to this at integration time; tests inject fakes.
protocol DispatcherResolving: Sendable {
    func dispatcher(for id: String) -> (any Dispatcher)?
}

/// Live, in-memory view of a dispatch in progress — updated on every event
/// (unlike the persisted log, which is flush-throttled). Survives after the
/// run finishes so the UI can keep showing the result summary.
struct LiveRun: Sendable, Equatable {
    var logTail: String = ""
    var activity: String?
    var resultText: String?
    var isFinished = false
}

/// Executes cards: validated status transitions, event streaming into the
/// persisted log (throttled) and a live tail (immediate), cancellation, and
/// terminal bookkeeping. One dispatch per card at a time; different cards
/// run concurrently.
@MainActor
@Observable
final class QueueRunner {
    /// Live state per card, kept after completion until retried or replaced.
    private(set) var liveRuns: [UUID: LiveRun] = [:]

    /// Fired once per run after its terminal state (and DB writes) are
    /// recorded: (cardID, success, resultText). Optional shell hook — the
    /// runner stays UI-agnostic and headless tests simply leave it nil.
    @ObservationIgnored var onRunFinished: ((UUID, Bool, String?) -> Void)?

    /// Cards left in the current "Run All" drain; nil when not draining.
    private(set) var drainRemaining: Int?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var drainCurrentCardID: UUID?

    @ObservationIgnored private let store: CardStore
    @ObservationIgnored private let resolver: any DispatcherResolving
    @ObservationIgnored private let flushInterval: Duration
    /// Log tails are capped so a verbose run can't grow memory unboundedly.
    @ObservationIgnored private let tailLimit: Int

    private struct RunHandle {
        /// The dispatcher's work; cancelling this (not `outer`) lets the
        /// cleanup in `run` proceed un-cancelled.
        let exec: Task<DispatchResult, Error>
        let outer: Task<Void, Never>
    }

    private var handles: [UUID: RunHandle] = [:]

    init(
        store: CardStore,
        resolver: any DispatcherResolving,
        flushInterval: Duration = .milliseconds(250),
        tailLimit: Int = 32_768
    ) {
        self.store = store
        self.resolver = resolver
        self.flushInterval = flushInterval
        self.tailLimit = tailLimit
    }

    func isActive(_ id: UUID) -> Bool {
        handles[id] != nil
    }

    /// Starts executing a queued card. Throws on double-dispatch or an
    /// illegal starting state; failures after the card leaves `queued`
    /// (unknown dispatcher, malformed params, dispatcher errors) are
    /// recorded on the card instead of thrown.
    func dispatch(cardID: UUID) async throws {
        guard handles[cardID] == nil else {
            throw QueueError.alreadyDispatching(cardID)
        }
        guard let card = try await store.fetch(id: cardID) else {
            throw PersistenceError.notFound(cardID)
        }
        // Validated queued → dispatched; also rejects re-dispatch of a
        // finished or already-dispatched card.
        try await store.setStatus(id: cardID, to: .dispatched)

        guard handles[cardID] == nil else {
            // A concurrent dispatch call won the race while we awaited.
            throw QueueError.alreadyDispatching(cardID)
        }

        liveRuns[cardID] = LiveRun()

        guard let dispatcher = resolver.dispatcher(for: card.dispatcherID) else {
            await failBeforeRun(cardID, message: "Unknown dispatcher: \(card.dispatcherID)")
            return
        }
        let params: [String: String]
        do {
            params = try QueueParams.decode(card.paramsJSON)
        } catch {
            await failBeforeRun(cardID, message: "Could not decode dispatcher parameters: \(error.localizedDescription)")
            return
        }

        let (events, continuation) = AsyncStream.makeStream(of: DispatchEvent.self)
        let prompt = card.prompt
        let exec = Task {
            defer { continuation.finish() }
            return try await dispatcher.execute(prompt: prompt, params: params) { event in
                continuation.yield(event)
            }
        }
        let outer = Task {
            await self.run(cardID: cardID, exec: exec, events: events)
        }
        handles[cardID] = RunHandle(exec: exec, outer: outer)
    }

    /// Cancels the dispatcher's work; the run loop then records the card as
    /// failed with a "Cancelled by user" log line.
    func cancel(cardID: UUID) {
        handles[cardID]?.exec.cancel()
    }

    /// Waits until the given card's in-flight run (if any) has fully
    /// finished, including its database writes.
    func awaitCompletion(cardID: UUID) async {
        await handles[cardID]?.outer.value
    }

    // MARK: - Run All (sequential drain)

    /// Dispatches every currently-dispatchable queued card, oldest first,
    /// strictly one at a time. Snapshot semantics: cards queued after the
    /// call are not picked up. A failing card doesn't stop the drain (its
    /// failure is surfaced like any other run); non-dispatchable cards are
    /// skipped and stay queued. Returns when the drain ends or is stopped.
    func runAll() async {
        guard drainTask == nil else { return }
        let cards = (try? await store.allNewestFirst()) ?? []
        let order = QueueLogic.drainOrder(cards: cards) { resolver.dispatcher(for: $0)?.paramSpecs }
        guard !order.isEmpty else { return }

        let task = Task { [weak self] in
            for (index, cardID) in order.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.drainRemaining = order.count - index
                self.drainCurrentCardID = cardID
                do {
                    try await self.dispatch(cardID: cardID)
                    await self.awaitCompletion(cardID: cardID)
                } catch {
                    // Raced state change (e.g. card deleted or dispatched by
                    // hand mid-drain) — skip it and keep draining.
                    voxiLog.notice("queue: run-all skipped \(cardID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
                }
            }
        }
        drainTask = task
        await task.value
        drainTask = nil
        drainCurrentCardID = nil
        drainRemaining = nil
    }

    /// Stops the drain: the in-flight card is cancelled (recorded failed,
    /// like any manual cancel); the cards not yet started stay queued.
    func stopDrain() {
        guard let task = drainTask else { return }
        task.cancel()
        if let current = drainCurrentCardID {
            cancel(cardID: current)
        }
    }

    var isDraining: Bool { drainRemaining != nil }

    // MARK: - Run loop

    private func run(
        cardID: UUID,
        exec: Task<DispatchResult, Error>,
        events: AsyncStream<DispatchEvent>
    ) async {
        let store = store
        let throttler = LogThrottler(interval: flushInterval) { chunk in
            do {
                try await store.appendLog(id: cardID, chunk: chunk)
            } catch {
                voxiLog.error("queue: log append failed for \(cardID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
            }
        }
        var movedToRunning = false

        func ensureRunning() async {
            guard !movedToRunning else { return }
            movedToRunning = true
            do {
                try await store.setStatus(id: cardID, to: .running)
            } catch {
                voxiLog.error("queue: running transition failed for \(cardID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
            }
        }

        for await event in events {
            await ensureRunning()
            switch event {
            case .log(let line):
                let chunk = line.hasSuffix("\n") ? line : line + "\n"
                appendTail(cardID, chunk)
                throttler.append(chunk)
            case .activity(let text):
                liveRuns[cardID, default: LiveRun()].activity = text
                let chunk = "▸ \(text)\n"
                appendTail(cardID, chunk)
                throttler.append(chunk)
            }
        }

        // The event stream only finishes when execute has returned or thrown,
        // so this await resolves immediately.
        let succeeded: Bool
        do {
            let result = try await exec.value
            if let text = result.resultText, !text.isEmpty {
                let chunk = text.hasSuffix("\n") ? text : text + "\n"
                appendTail(cardID, chunk)
                throttler.append(chunk)
                liveRuns[cardID]?.resultText = text
            }
            await throttler.finish()
            // A success with zero events still needs dispatched → running
            // before the terminal transition (running → succeeded).
            await ensureRunning()
            await recordFinish(
                cardID, success: result.success, exitCode: result.exitCode,
                sessionID: result.sessionID)
            succeeded = result.success
        } catch is CancellationError {
            let line = "Cancelled by user\n"
            appendTail(cardID, line)
            throttler.append(line)
            await throttler.finish()
            liveRuns[cardID]?.resultText = "Cancelled by user"
            await recordFinish(cardID, success: false, exitCode: nil)
            succeeded = false
        } catch {
            let line = "Dispatch failed: \(error.localizedDescription)\n"
            appendTail(cardID, line)
            throttler.append(line)
            await throttler.finish()
            liveRuns[cardID]?.resultText = error.localizedDescription
            await recordFinish(cardID, success: false, exitCode: nil)
            succeeded = false
        }

        liveRuns[cardID]?.activity = nil
        liveRuns[cardID]?.isFinished = true
        handles[cardID] = nil
        onRunFinished?(cardID, succeeded, liveRuns[cardID]?.resultText)
    }

    private func appendTail(_ cardID: UUID, _ chunk: String) {
        var run = liveRuns[cardID, default: LiveRun()]
        run.logTail += chunk
        if run.logTail.count > tailLimit {
            run.logTail = String(run.logTail.suffix(tailLimit))
        }
        liveRuns[cardID] = run
    }

    private func recordFinish(_ cardID: UUID, success: Bool, exitCode: Int?, sessionID: String? = nil) async {
        do {
            try await store.finish(id: cardID, success: success, exitCode: exitCode, sessionID: sessionID)
        } catch {
            voxiLog.error("queue: result write failed for \(cardID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
        }
    }

    /// Spawn-stage failure: the card is `dispatched` but no work ever ran.
    private func failBeforeRun(_ cardID: UUID, message: String) async {
        appendTail(cardID, message + "\n")
        liveRuns[cardID]?.resultText = message
        liveRuns[cardID]?.isFinished = true
        do {
            try await store.appendLog(id: cardID, chunk: message + "\n")
            try await store.finish(id: cardID, success: false, exitCode: nil)
        } catch {
            voxiLog.error("queue: spawn-failure write failed for \(cardID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
        }
        onRunFinished?(cardID, false, message)
    }
}
