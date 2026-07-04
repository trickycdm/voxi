import Foundation
import SwiftUI
import Testing
@testable import Voxi

private func makeDraft(
    title: String = "Build climbing tracker",
    prompt: String = "Create a Next.js web app that tracks climbing sessions."
) -> CardDraft {
    CardDraft(
        title: title,
        summary: "Next.js app in repos folder",
        prompt: prompt,
        refinedByLLM: true
    )
}

@MainActor
private func makeModel() throws -> (QueueModel, CardStore) {
    let store = CardStore(database: try AppDatabase(inMemory: true))
    return (QueueModel(store: store), store)
}

@MainActor
@Suite struct QueueModelTests {
    @Test func addCardPersistsQueuedCardWithEncodedParams() async throws {
        let (model, store) = try makeModel()
        let card = try await model.addCard(
            draft: makeDraft(),
            rawTranscript: "create a web app that tracks my climbing",
            dispatcherID: "claude-code",
            params: ["workingDirectory": "/tmp/repos", "extraFlags": ""]
        )

        let stored = try #require(try await store.fetch(id: card.id))
        #expect(stored.status == .queued)
        #expect(stored.title == "Build climbing tracker")
        #expect(stored.prompt == "Create a Next.js web app that tracks climbing sessions.")
        #expect(stored.rawTranscript == "create a web app that tracks my climbing")
        #expect(stored.refinedByLLM)
        #expect(stored.dispatcherID == "claude-code")
        #expect(try QueueParams.decode(stored.paramsJSON) == [
            "workingDirectory": "/tmp/repos", "extraFlags": "",
        ])
        #expect(stored.log.isEmpty)
        #expect(stored.exitCode == nil)
    }

    @Test func loadReturnsCardsNewestFirst() async throws {
        let (model, _) = try makeModel()
        let older = try await model.addCard(
            draft: makeDraft(title: "First"), rawTranscript: "a", dispatcherID: "d"
        )
        let newer = try await model.addCard(
            draft: makeDraft(title: "Second"), rawTranscript: "b", dispatcherID: "d"
        )
        try await model.load()
        #expect(model.cards.map(\.id) == [newer.id, older.id])
    }

    @Test func editsApplyWhileQueued() async throws {
        let (model, store) = try makeModel()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")

        try await model.updatePrompt(id: card.id, to: "Updated prompt")
        try await model.updateTitle(id: card.id, to: "Updated title")
        try await model.updateParams(id: card.id, to: ["workingDirectory": "/repos"])

        let stored = try #require(try await store.fetch(id: card.id))
        #expect(stored.prompt == "Updated prompt")
        #expect(stored.title == "Updated title")
        #expect(try QueueParams.decode(stored.paramsJSON) == ["workingDirectory": "/repos"])
    }

    @Test func editsRejectedOnceDispatched() async throws {
        let (model, store) = try makeModel()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")
        try await store.setStatus(id: card.id, to: .dispatched)

        await #expect(throws: QueueError.cardNotEditable(.dispatched)) {
            try await model.updatePrompt(id: card.id, to: "too late")
        }
        let stored = try #require(try await store.fetch(id: card.id))
        #expect(stored.prompt == makeDraft().prompt)
    }

    @Test func editUnknownCardThrowsNotFound() async throws {
        let (model, _) = try makeModel()
        let ghost = UUID()
        await #expect(throws: PersistenceError.notFound(ghost)) {
            try await model.updatePrompt(id: ghost, to: "x")
        }
    }

    @Test func deleteRemovesCard() async throws {
        let (model, store) = try makeModel()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")
        try await model.delete(id: card.id)
        #expect(try await store.fetch(id: card.id) == nil)
    }

    @Test func retryResetsFailedCardToQueued() async throws {
        let (model, store) = try makeModel()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")
        try await store.setStatus(id: card.id, to: .dispatched)
        try await store.setStatus(id: card.id, to: .running)
        try await store.appendLog(id: card.id, chunk: "boom\n")
        try await store.setResult(id: card.id, exitCode: 1)

        try await model.retry(id: card.id)

        let stored = try #require(try await store.fetch(id: card.id))
        #expect(stored.status == .queued)
        #expect(stored.log.isEmpty)
        #expect(stored.exitCode == nil)
        #expect(stored.dispatchedAt == nil)
        #expect(stored.finishedAt == nil)
    }

    @Test func retryRejectedUnlessFailed() async throws {
        let (model, _) = try makeModel()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")
        await #expect(throws: PersistenceError.illegalTransition(from: .queued, to: .queued)) {
            try await model.retry(id: card.id)
        }
    }

    @Test func observationUpdatesCardsAfterInsert() async throws {
        let (model, _) = try makeModel()
        model.startObserving()
        let card = try await model.addCard(draft: makeDraft(), rawTranscript: "r", dispatcherID: "d")
        let deadline = Date().addingTimeInterval(5)
        while model.cards.first?.id != card.id, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.cards.first?.id == card.id)
        model.stopObserving()
    }
}

@Suite struct QueueParamsTests {
    @Test func encodeDecodeRoundTrip() throws {
        let params = ["workingDirectory": "/tmp", "extraFlags": "--verbose"]
        let json = try QueueParams.encode(params)
        #expect(try QueueParams.decode(json) == params)
    }

    @Test func encodeSortsKeysDeterministically() throws {
        let json = try QueueParams.encode(["b": "2", "a": "1"])
        #expect(json == #"{"a":"1","b":"2"}"#)
    }

    @Test func decodeRejectsMalformedJSON() {
        #expect(throws: Error.self) {
            try QueueParams.decode("not json")
        }
        #expect(throws: Error.self) {
            try QueueParams.decode(#"{"nested":{"a":1}}"#)
        }
    }
}

@Suite struct RecentDirsTests {
    @Test func insertingPrependsAndDedupes() {
        let list = ["/a", "/b", "/c"]
        #expect(RecentDirs.inserting("/b", into: list) == ["/b", "/a", "/c"])
        #expect(RecentDirs.inserting("/new", into: list) == ["/new", "/a", "/b", "/c"])
    }

    @Test func insertingCapsLength() {
        let list = (1...8).map { "/dir\($0)" }
        let updated = RecentDirs.inserting("/fresh", into: list)
        #expect(updated.count == 8)
        #expect(updated.first == "/fresh")
        #expect(!updated.contains("/dir8"))
    }

    @Test func insertingIgnoresBlankPaths() {
        #expect(RecentDirs.inserting("   ", into: ["/a"]) == ["/a"])
    }
}

@Suite struct QueueLogicTests {
    private let specs = [
        DispatcherParamSpec(id: "workingDirectory", label: "Working directory", kind: .directory, required: true),
        DispatcherParamSpec(id: "extraFlags", label: "Extra flags", kind: .string, required: false),
    ]

    @Test func dispatchRequiresQueuedStatus() {
        let params = ["workingDirectory": "/tmp"]
        #expect(QueueLogic.canDispatch(status: .queued, params: params, specs: specs))
        for status in CardStatus.allCases where status != .queued {
            #expect(!QueueLogic.canDispatch(status: status, params: params, specs: specs))
        }
    }

    @Test func dispatchRequiresRequiredParams() {
        #expect(!QueueLogic.canDispatch(status: .queued, params: [:], specs: specs))
        #expect(!QueueLogic.canDispatch(status: .queued, params: ["workingDirectory": "   "], specs: specs))
        #expect(QueueLogic.canDispatch(status: .queued, params: ["workingDirectory": "/tmp"], specs: specs))
        // Optional params may be absent.
        #expect(QueueLogic.canDispatch(
            status: .queued,
            params: ["workingDirectory": "/tmp", "extraFlags": ""],
            specs: specs
        ))
    }

    @Test func statusChipMapping() {
        #expect(CardStatus.queued.chipColor == .gray)
        #expect(CardStatus.dispatched.chipColor == .orange)
        #expect(CardStatus.running.chipColor == .blue)
        #expect(CardStatus.succeeded.chipColor == .green)
        #expect(CardStatus.failed.chipColor == .red)
        #expect(CardStatus.running.showsSpinner)
        for status in CardStatus.allCases where status != .running {
            #expect(!status.showsSpinner)
        }
        #expect(CardStatus.queued.chipLabel == "Queued")
    }

    @Test func refinementBadgeSaysSo() {
        #expect(QueueLogic.refinementBadge(refinedByLLM: true) == "Refined by LLM")
        #expect(QueueLogic.refinementBadge(refinedByLLM: false)
            == "Cleaned transcript used verbatim — no LLM configured")
    }
}

@MainActor
@Suite struct LogThrottlerTests {
    @MainActor
    final class Recorder {
        private(set) var chunks: [String] = []
        func record(_ chunk: String) { chunks.append(chunk) }
        var joined: String { chunks.joined() }
    }

    @Test func finishFlushesEverythingWithoutWaitingForInterval() async {
        let recorder = Recorder()
        // Interval far longer than the test: only finish() can flush.
        let throttler = LogThrottler(interval: .seconds(60)) { recorder.record($0) }
        throttler.append("one\n")
        throttler.append("two\n")
        #expect(recorder.chunks.isEmpty)
        await throttler.finish()
        #expect(recorder.joined == "one\ntwo\n")
        #expect(recorder.chunks.count == 1)
    }

    @Test func periodicFlushCoalescesBursts() async throws {
        let recorder = Recorder()
        let throttler = LogThrottler(interval: .milliseconds(20)) { recorder.record($0) }
        throttler.append("a\n")
        throttler.append("b\n")
        let deadline = Date().addingTimeInterval(5)
        while recorder.chunks.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(recorder.chunks == ["a\nb\n"])
        throttler.append("c\n")
        await throttler.finish()
        #expect(recorder.joined == "a\nb\nc\n")
    }

    @Test func appendsAfterFinishAreDropped() async {
        let recorder = Recorder()
        let throttler = LogThrottler(interval: .milliseconds(1)) { recorder.record($0) }
        throttler.append("kept\n")
        await throttler.finish()
        throttler.append("dropped\n")
        await throttler.finish()
        #expect(recorder.joined == "kept\n")
    }

    @Test func finishWithEmptyBufferFlushesNothing() async {
        let recorder = Recorder()
        let throttler = LogThrottler(interval: .milliseconds(1)) { recorder.record($0) }
        await throttler.finish()
        #expect(recorder.chunks.isEmpty)
    }
}
