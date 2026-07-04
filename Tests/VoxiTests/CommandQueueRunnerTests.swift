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

    let id = "fake"
    let displayName = "Fake Dispatcher"
    let paramSpecs = [
        DispatcherParamSpec(id: "workingDirectory", label: "Working directory", kind: .directory, required: true)
    ]
    let script: Script
    let recorder = InvocationRecorder()

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
