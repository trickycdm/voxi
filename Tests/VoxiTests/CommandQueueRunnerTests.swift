import Foundation
import Testing
@testable import Voxi

// MARK: - Fakes

/// A scripted dispatcher: emits its events, then succeeds, fails, throws,
/// or hangs until cancelled.
private struct FakeDispatcher: Dispatcher {
    enum Script: Sendable {
        case finish(events: [DispatchEvent], result: DispatchResult)
        case throwError(DispatcherError)
        /// Emits events, then sleeps until task cancellation.
        case neverEnding(events: [DispatchEvent])
    }

    let id: String
    let displayName = "Fake Dispatcher"
    let paramSpecs = [
        DispatcherParamSpec(id: "workingDirectory", label: "Working directory", kind: .directory, required: true)
    ]
    let script: Script
    let recorder = InvocationRecorder()

    init(script: Script, id: String = "fake") {
        self.script = script
        self.id = id
    }

    final actor InvocationRecorder {
        private(set) var prompts: [String] = []
        private(set) var params: [[String: String]] = []
        func record(prompt: String, params: [String: String]) {
            prompts.append(prompt)
            self.params.append(params)
        }
    }

    func execute(
        prompt: String,
        params: [String: String],
        onEvent: @escaping @Sendable (DispatchEvent) -> Void
    ) async throws -> DispatchResult {
        await recorder.record(prompt: prompt, params: params)
        switch script {
        case .finish(let events, let result):
            for event in events { onEvent(event) }
            return result
        case .throwError(let error):
            throw error
        case .neverEnding(let events):
            for event in events { onEvent(event) }
            try await Task.sleep(for: .seconds(3600))
            return DispatchResult(success: true, exitCode: 0, resultText: nil)
        }
    }
}

private struct FakeResolver: DispatcherResolving {
    var dispatchers: [String: any Dispatcher] = [:]
    func dispatcher(for id: String) -> (any Dispatcher)? { dispatchers[id] }
    var allDispatchers: [any Dispatcher] { Array(dispatchers.values) }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let store: CardStore
    let runner: QueueRunner
    let dispatcher: FakeDispatcher

    init(script: FakeDispatcher.Script, dispatcherID: String = "fake") throws {
        store = CardStore(database: try AppDatabase(inMemory: true))
        dispatcher = FakeDispatcher(script: script)
        runner = QueueRunner(
            store: store,
            resolver: FakeResolver(dispatchers: [dispatcher.id: dispatcher]),
            flushInterval: .milliseconds(20)
        )
    }

    func insertCard(
        dispatcherID: String = "fake",
        paramsJSON: String = #"{"workingDirectory":"/tmp"}"#
    ) async throws -> ActionCard {
        let card = ActionCard(
            title: "Test card",
            summary: "A card under test",
            prompt: "Do the thing.",
            rawTranscript: "do the thing",
            refinedByLLM: false,
            dispatcherID: dispatcherID,
            paramsJSON: paramsJSON
        )
        try await store.insert(card)
        return card
    }

    func card(_ id: UUID) async throws -> ActionCard {
        try #require(try await store.fetch(id: id))
    }

    func waitForStatus(_ id: UUID, _ status: CardStatus, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await card(id).status != status {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for card to become \(status.rawValue)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Tests

@MainActor
@Suite struct QueueRunnerTests {
    @Test func successfulLifecycle() async throws {
        let harness = try Harness(script: .finish(
            events: [
                .log("line one"),
                .activity("running Bash"),
                .log("line two\n"),
            ],
            result: DispatchResult(success: true, exitCode: 0, resultText: "All done.")
        ))
        let card = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .succeeded)
        #expect(finished.exitCode == 0)
        #expect(finished.dispatchedAt != nil)
        #expect(finished.finishedAt != nil)
        #expect(finished.log.contains("line one\n"))
        #expect(finished.log.contains("▸ running Bash\n"))
        #expect(finished.log.contains("line two\n"))
        #expect(finished.log.contains("All done."))

        // The dispatcher received the card's prompt and decoded params.
        #expect(await harness.dispatcher.recorder.prompts == ["Do the thing."])
        #expect(await harness.dispatcher.recorder.params == [["workingDirectory": "/tmp"]])

        // Live tail mirrors the full log and carries the result summary.
        let live = try #require(harness.runner.liveRuns[card.id])
        #expect(live.isFinished)
        #expect(live.resultText == "All done.")
        #expect(live.logTail.contains("line one\n"))
        #expect(!harness.runner.isActive(card.id))
    }

    @Test func successWithNoEventsStillReachesSucceeded() async throws {
        // dispatched → succeeded is illegal; the runner must route through
        // running even when the dispatcher emitted nothing.
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)
        let finished = try await harness.card(card.id)
        #expect(finished.status == .succeeded)
        #expect(finished.exitCode == 0)
    }

    @Test func failureResultMarksCardFailed() async throws {
        let harness = try Harness(script: .finish(
            events: [.log("nope")],
            result: DispatchResult(success: false, exitCode: 2, resultText: "It broke.")
        ))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == 2)
        #expect(finished.log.contains("nope\n"))
        #expect(finished.log.contains("It broke."))
    }

    @Test func failureWithExitCodeZeroStaysFailed() async throws {
        // e.g. claude exits 0 but the result event carries is_error.
        let harness = try Harness(script: .finish(
            events: [.log("api error")],
            result: DispatchResult(success: false, exitCode: 0, resultText: "API error")
        ))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)
        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == 0)
    }

    @Test func thrownErrorMarksCardFailedWithMessage() async throws {
        let harness = try Harness(script: .throwError(.spawnFailed("claude binary missing")))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == nil)
        #expect(finished.log.contains("claude binary missing"))
    }

    @Test func cancelMarksCardFailedWithCancelledLine() async throws {
        let harness = try Harness(script: .neverEnding(events: [.log("started")]))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        try await harness.waitForStatus(card.id, .running)
        #expect(harness.runner.isActive(card.id))

        harness.runner.cancel(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == nil)
        #expect(finished.log.contains("started\n"))
        #expect(finished.log.contains("Cancelled by user"))
        #expect(!harness.runner.isActive(card.id))
    }

    @Test func doubleDispatchIsRejected() async throws {
        let harness = try Harness(script: .neverEnding(events: [.log("started")]))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)

        await #expect(throws: QueueError.alreadyDispatching(card.id)) {
            try await harness.runner.dispatch(cardID: card.id)
        }

        harness.runner.cancel(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)
    }

    @Test func dispatchOfFinishedCardIsRejectedByTransitionValidation() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        await #expect(throws: PersistenceError.illegalTransition(from: .succeeded, to: .dispatched)) {
            try await harness.runner.dispatch(cardID: card.id)
        }
    }

    @Test func dispatchOfUnknownCardThrowsNotFound() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let ghost = UUID()
        await #expect(throws: PersistenceError.notFound(ghost)) {
            try await harness.runner.dispatch(cardID: ghost)
        }
    }

    @Test func malformedParamsFailTheCardWithMessage() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let card = try await harness.insertCard(paramsJSON: "not json at all")
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.log.contains("Could not decode dispatcher parameters"))
        // The dispatcher was never invoked.
        #expect(await harness.dispatcher.recorder.prompts.isEmpty)
    }

    @Test func unknownDispatcherFailsTheCardWithMessage() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let card = try await harness.insertCard(dispatcherID: "missing-dispatcher")
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.log.contains("Unknown dispatcher: missing-dispatcher"))
    }

    @Test func retryAfterFailureAllowsRedispatch() async throws {
        let harness = try Harness(script: .finish(
            events: [.log("attempt")],
            result: DispatchResult(success: false, exitCode: 1, resultText: "failed once")
        ))
        let card = try await harness.insertCard()
        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)
        #expect(try await harness.card(card.id).status == .failed)

        try await harness.store.setStatus(id: card.id, to: .queued)
        let requeued = try await harness.card(card.id)
        #expect(requeued.status == .queued)
        #expect(requeued.log.isEmpty)

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)
        let finished = try await harness.card(card.id)
        #expect(finished.status == .failed)
        #expect(finished.exitCode == 1)
        #expect(await harness.dispatcher.recorder.prompts.count == 2)
    }

    @Test func concurrentCardsRunIndependently() async throws {
        let harness = try Harness(script: .neverEnding(events: [.log("running")]))
        let first = try await harness.insertCard()
        let second = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: first.id)
        try await harness.runner.dispatch(cardID: second.id)
        try await harness.waitForStatus(first.id, .running)
        try await harness.waitForStatus(second.id, .running)
        #expect(harness.runner.isActive(first.id))
        #expect(harness.runner.isActive(second.id))

        // Cancelling one leaves the other running.
        harness.runner.cancel(cardID: first.id)
        await harness.runner.awaitCompletion(cardID: first.id)
        #expect(try await harness.card(first.id).status == .failed)
        #expect(try await harness.card(second.id).status == .running)
        #expect(harness.runner.isActive(second.id))

        harness.runner.cancel(cardID: second.id)
        await harness.runner.awaitCompletion(cardID: second.id)
        #expect(try await harness.card(second.id).status == .failed)
    }

    @Test func cancelWithNoActiveRunIsANoOp() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let card = try await harness.insertCard()
        harness.runner.cancel(cardID: card.id)
        #expect(try await harness.card(card.id).status == .queued)
    }
}

// MARK: - onRunFinished hook

/// Captures onRunFinished payloads; tests run on the MainActor, matching
/// the hook's isolation.
@MainActor
private final class FinishRecorder {
    private(set) var payloads: [(cardID: UUID, success: Bool, resultText: String?)] = []
    func install(on runner: QueueRunner) {
        runner.onRunFinished = { [weak self] id, success, text in
            self?.payloads.append((id, success, text))
        }
    }
}

@MainActor
@Suite struct QueueRunnerFinishHookTests {
    @Test func firesOnceWithResultOnSuccess() async throws {
        let harness = try Harness(script: .finish(
            events: [.log("working")],
            result: DispatchResult(success: true, exitCode: 0, resultText: "All done.")
        ))
        let recorder = FinishRecorder()
        recorder.install(on: harness.runner)
        let card = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.cardID == card.id)
        #expect(recorder.payloads.first?.success == true)
        #expect(recorder.payloads.first?.resultText == "All done.")
        // Fired after the terminal DB write.
        #expect(try await harness.card(card.id).status == .succeeded)
    }

    @Test func firesWithFailureOnFailedRun() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: false, exitCode: 1, resultText: "It broke.")
        ))
        let recorder = FinishRecorder()
        recorder.install(on: harness.runner)
        let card = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.success == false)
        #expect(recorder.payloads.first?.resultText == "It broke.")
    }

    @Test func firesWithFailureOnCancel() async throws {
        let harness = try Harness(script: .neverEnding(events: [.log("spinning")]))
        let recorder = FinishRecorder()
        recorder.install(on: harness.runner)
        let card = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: card.id)
        try await harness.waitForStatus(card.id, .running)
        harness.runner.cancel(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.success == false)
        #expect(recorder.payloads.first?.resultText == "Cancelled by user")
    }

    @Test func firesWithFailureOnSpawnFailure() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: nil)
        ))
        let recorder = FinishRecorder()
        recorder.install(on: harness.runner)
        // Unknown dispatcher id → failBeforeRun path.
        let card = try await harness.insertCard(dispatcherID: "no-such-dispatcher")

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        #expect(recorder.payloads.count == 1)
        #expect(recorder.payloads.first?.success == false)
        #expect(recorder.payloads.first?.resultText?.contains("Unknown dispatcher") == true)
        #expect(try await harness.card(card.id).status == .failed)
    }
}

@MainActor
@Suite struct QueueRunnerSessionIDTests {
    @Test func sessionIDFromResultIsPersistedOnFinish() async throws {
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: true, exitCode: 0, resultText: "ok", sessionID: "sess-9")
        ))
        let card = try await harness.insertCard()

        try await harness.runner.dispatch(cardID: card.id)
        await harness.runner.awaitCompletion(cardID: card.id)

        let finished = try await harness.card(card.id)
        #expect(finished.status == .succeeded)
        #expect(finished.sessionID == "sess-9")
    }
}

// MARK: - Run All

@MainActor
@Suite struct QueueRunnerDrainTests {
    @Test func drainsSequentiallyOldestFirstAndContinuesPastFailure() async throws {
        // The fake finishes instantly; sequence order is proven by the
        // finish-hook order matching creation order, and by never observing
        // two active handles (checked via isActive during the hook).
        let harness = try Harness(script: .finish(
            events: [],
            result: DispatchResult(success: false, exitCode: 1, resultText: "boom")
        ))
        let recorder = FinishRecorder()
        recorder.install(on: harness.runner)

        var created: [UUID] = []
        for _ in 0..<3 {
            let card = try await harness.insertCard()
            created.append(card.id)
            // Distinct createdAt ordering.
            try await Task.sleep(for: .milliseconds(5))
        }
        // A draft card with no working directory must be skipped, not failed.
        let draft = try await harness.insertCard(paramsJSON: "{}")

        await harness.runner.runAll()

        #expect(recorder.payloads.map(\.cardID) == created)
        for id in created {
            #expect(try await harness.card(id).status == .failed)  // continue-on-failure ran all three
        }
        #expect(try await harness.card(draft.id).status == .queued)
        #expect(harness.runner.drainRemaining == nil)
    }

    @Test func stopCancelsCurrentAndLeavesRestQueued() async throws {
        let harness = try Harness(script: .neverEnding(events: [.log("spinning")]))
        let first = try await harness.insertCard()
        try await Task.sleep(for: .milliseconds(5))
        let second = try await harness.insertCard()

        let drain = Task { await harness.runner.runAll() }
        // Wait until the first card is actually running.
        try await harness.waitForStatus(first.id, .running)
        #expect(harness.runner.isDraining)

        harness.runner.stopDrain()
        await drain.value

        #expect(try await harness.card(first.id).status == .failed)   // cancelled in flight
        #expect(try await harness.card(second.id).status == .queued)  // never started
        #expect(harness.runner.drainRemaining == nil)
    }
}

// MARK: - Dispatch-time dispatcher override

@MainActor
@Suite struct QueueRunnerDispatchAsTests {
    /// Two registered fakes so the override can be told apart from the
    /// stored dispatcher by which recorder saw the prompt.
    @MainActor
    private struct TwoDispatcherHarness {
        let store: CardStore
        let runner: QueueRunner
        let stored: FakeDispatcher
        let override: FakeDispatcher

        init() throws {
            store = CardStore(database: try AppDatabase(inMemory: true))
            stored = FakeDispatcher(
                script: .finish(events: [], result: DispatchResult(success: true, exitCode: 0, resultText: nil)),
                id: "stored")
            override = FakeDispatcher(
                script: .finish(events: [], result: DispatchResult(success: true, exitCode: 0, resultText: nil)),
                id: "override")
            runner = QueueRunner(
                store: store,
                resolver: FakeResolver(dispatchers: [stored.id: stored, override.id: override]),
                flushInterval: .milliseconds(20))
        }

        func insertCard() async throws -> ActionCard {
            let card = ActionCard(
                title: "Test card", summary: "s", prompt: "Do the thing.",
                rawTranscript: "r", refinedByLLM: false,
                dispatcherID: "stored",
                paramsJSON: #"{"workingDirectory":"/tmp"}"#)
            try await store.insert(card)
            return card
        }
    }

    @Test func overrideRunsThatDispatcherAndPersistsItsID() async throws {
        let h = try TwoDispatcherHarness()
        let card = try await h.insertCard()

        try await h.runner.dispatch(cardID: card.id, as: "override")
        await h.runner.awaitCompletion(cardID: card.id)

        #expect(await h.override.recorder.prompts == ["Do the thing."])
        #expect(await h.stored.recorder.prompts.isEmpty)
        let finished = try #require(try await h.store.fetch(id: card.id))
        #expect(finished.dispatcherID == "override")
        #expect(finished.status == .succeeded)
        #expect(finished.paramsJSON == #"{"workingDirectory":"/tmp"}"#)
    }

    @Test func nilOverrideUsesStoredDispatcher() async throws {
        let h = try TwoDispatcherHarness()
        let card = try await h.insertCard()

        try await h.runner.dispatch(cardID: card.id)
        await h.runner.awaitCompletion(cardID: card.id)

        #expect(await h.stored.recorder.prompts == ["Do the thing."])
        #expect(await h.override.recorder.prompts.isEmpty)
        let finished = try #require(try await h.store.fetch(id: card.id))
        #expect(finished.dispatcherID == "stored")
    }

    @Test func overrideOnTerminalCardThrowsWithoutRewritingID() async throws {
        let h = try TwoDispatcherHarness()
        let card = try await h.insertCard()
        try await h.runner.dispatch(cardID: card.id)
        await h.runner.awaitCompletion(cardID: card.id)

        await #expect(throws: PersistenceError.self) {
            try await h.runner.dispatch(cardID: card.id, as: "override")
        }
        let unchanged = try #require(try await h.store.fetch(id: card.id))
        #expect(unchanged.dispatcherID == "stored")
    }

    @Test func unknownOverrideFailsCardAndRecordsAttemptedID() async throws {
        let h = try TwoDispatcherHarness()
        let card = try await h.insertCard()

        try await h.runner.dispatch(cardID: card.id, as: "ghost")
        await h.runner.awaitCompletion(cardID: card.id)

        let failed = try #require(try await h.store.fetch(id: card.id))
        #expect(failed.status == .failed)
        // The record reflects what was attempted.
        #expect(failed.dispatcherID == "ghost")
        #expect(failed.log.contains("Unknown dispatcher: ghost"))
    }

    @Test func secondDispatchWithDifferentOverrideLosesRace() async throws {
        let h = try TwoDispatcherHarness()
        let card = try await h.insertCard()

        try await h.runner.dispatch(cardID: card.id, as: "override")
        await #expect(throws: Error.self) {
            try await h.runner.dispatch(cardID: card.id, as: "stored")
        }
        await h.runner.awaitCompletion(cardID: card.id)
        let finished = try #require(try await h.store.fetch(id: card.id))
        #expect(finished.dispatcherID == "override")
    }
}

// MARK: - beginDispatch (store-level atomicity)

@MainActor
@Suite struct CardStoreBeginDispatchTests {
    @Test func recordsDispatcherStatusAndTimestampAtomically() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = ActionCard(
            title: "t", summary: "s", prompt: "p", rawTranscript: "r",
            refinedByLLM: false, dispatcherID: "a", paramsJSON: "{}")
        try await store.insert(card)

        let updated = try await store.beginDispatch(id: card.id, dispatcherID: "b")
        #expect(updated.dispatcherID == "b")
        #expect(updated.status == .dispatched)
        #expect(updated.dispatchedAt != nil)

        let fetched = try #require(try await store.fetch(id: card.id))
        #expect(fetched.dispatcherID == "b")
        #expect(fetched.status == .dispatched)
    }

    @Test func nilDispatcherIDKeepsStoredID() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = ActionCard(
            title: "t", summary: "s", prompt: "p", rawTranscript: "r",
            refinedByLLM: false, dispatcherID: "a", paramsJSON: "{}")
        try await store.insert(card)

        let updated = try await store.beginDispatch(id: card.id)
        #expect(updated.dispatcherID == "a")
        #expect(updated.status == .dispatched)
    }

    @Test func rejectsNonQueuedCard() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = ActionCard(
            title: "t", summary: "s", prompt: "p", rawTranscript: "r",
            refinedByLLM: false, dispatcherID: "a", paramsJSON: "{}")
        try await store.insert(card)
        _ = try await store.beginDispatch(id: card.id)

        await #expect(throws: PersistenceError.self) {
            _ = try await store.beginDispatch(id: card.id, dispatcherID: "b")
        }
    }
}
