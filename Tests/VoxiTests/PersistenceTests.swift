import Foundation
import GRDB
import Testing
@testable import Voxi

// Whole-second dates round-trip exactly through GRDB's datetime storage,
// letting tests use full struct equality.
private func fixedDate(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: 1_750_000_000 + offset)
}

private func makeHistoryEntry(
    raw: String = "the quick brown fox",
    final: String = "The quick brown fox.",
    createdAt: Date = fixedDate()
) -> HistoryEntry {
    HistoryEntry(
        createdAt: createdAt,
        rawTranscript: raw,
        finalText: final,
        engineID: "fluid.parakeet",
        modelID: "parakeet-tdt-0.6b-v3",
        refinerID: "rules",
        targetAppBundleID: "com.apple.TextEdit",
        durationSeconds: 2.5
    )
}

private func makeCard(
    title: String = "Build climbing tracker",
    createdAt: Date = fixedDate()
) -> ActionCard {
    ActionCard(
        createdAt: createdAt,
        title: title,
        summary: "Next.js app in repos folder",
        prompt: "Create a Next.js web app that tracks climbing sessions.",
        rawTranscript: "create a new web app that tracks my climbing sessions",
        refinedByLLM: true,
        dispatcherID: "claude-code",
        paramsJSON: #"{"workingDirectory":"/tmp"}"#
    )
}

@Suite struct MigrationTests {
    @Test func v1CreatesAllTables() async throws {
        let db = try AppDatabase(inMemory: true)
        let tables = try await db.dbQueue.read { db in
            try (
                history: db.tableExists("history"),
                fts: db.tableExists("history_ft"),
                dictionary: db.tableExists("dictionaryEntry"),
                card: db.tableExists("actionCard")
            )
        }
        #expect(tables.history)
        #expect(tables.fts)
        #expect(tables.dictionary)
        #expect(tables.card)
    }

    @Test func v2AddsSessionIDPreservingV1Rows() async throws {
        // Build a database exactly as a v1 install left it, with a row.
        let queue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v1")
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO actionCard
                  (uuid, createdAt, title, summary, prompt, rawTranscript, refinedByLLM,
                   status, dispatcherID, paramsJSON, log, exitCode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["11111111-1111-1111-1111-111111111111", fixedDate(), "Old card", "s", "p", "r",
                            true, "succeeded", "claude-code", "{}", "old log", 0]
            )
        }

        try migrator.migrate(queue)

        let migrated = try #require(try await queue.read { db in
            try ActionCard.fetchOne(db, key: "11111111-1111-1111-1111-111111111111")
        })
        #expect(migrated.title == "Old card")
        #expect(migrated.status == .succeeded)
        #expect(migrated.log == "old log")
        #expect(migrated.sessionID == nil)
    }
}

@Suite struct FTSQuerySanitizerTests {
    @Test func tokensAreQuoted() {
        #expect(FTSQuery.sanitizedMatchPattern("foo OR bar") == "\"foo\" \"OR\" \"bar\"")
    }
    @Test func embeddedQuotesAreEscaped() {
        #expect(FTSQuery.sanitizedMatchPattern(#"say "hi""#) == "\"say\" \"\"\"hi\"\"\"")
    }
    @Test func emptyAndPunctuationOnlyAreNil() {
        #expect(FTSQuery.sanitizedMatchPattern("") == nil)
        #expect(FTSQuery.sanitizedMatchPattern("   ") == nil)
        #expect(FTSQuery.sanitizedMatchPattern("!!! ***") == nil)
    }
}

@Suite struct HistoryStoreTests {
    @Test func saveAndFetchRoundTrip() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let entry = makeHistoryEntry()
        try await store.save(entry)
        let fetched = try await store.recent(limit: 10)
        #expect(fetched == [entry]) // includes UUID round-trip via Equatable
    }

    @Test func uuidStoredAsLowercasedString() async throws {
        let db = try AppDatabase(inMemory: true)
        let store = HistoryStore(database: db)
        let entry = makeHistoryEntry()
        try await store.save(entry)
        let stored = try await db.dbQueue.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT uuid FROM history")
        }
        #expect(stored == entry.id.uuidString.lowercased())
    }

    @Test func recentOrdersNewestFirstAndPages() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let a = makeHistoryEntry(raw: "oldest", createdAt: fixedDate(0))
        let b = makeHistoryEntry(raw: "middle", createdAt: fixedDate(10))
        let c = makeHistoryEntry(raw: "newest", createdAt: fixedDate(20))
        for entry in [a, b, c] { try await store.save(entry) }

        let firstPage = try await store.recent(limit: 2)
        #expect(firstPage == [c, b])
        let secondPage = try await store.recent(limit: 2, offset: 2)
        #expect(secondPage == [a])
    }

    @Test func searchMatchesRawTranscript() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let entry = makeHistoryEntry(raw: "remember the zanzibar deadline", final: "Something else.")
        try await store.save(entry)
        let hits = try await store.search(query: "zanzibar")
        #expect(hits == [entry])
    }

    @Test func searchMatchesFinalText() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let entry = makeHistoryEntry(raw: "something else", final: "The polished quixotic output.")
        try await store.save(entry)
        let hits = try await store.search(query: "quixotic")
        #expect(hits == [entry])
    }

    @Test func searchNoMatchReturnsEmpty() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        try await store.save(makeHistoryEntry())
        let hits = try await store.search(query: "zebra")
        #expect(hits.isEmpty)
    }

    @Test func searchEmptyQueryReturnsEmpty() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        try await store.save(makeHistoryEntry())
        #expect(try await store.search(query: "").isEmpty)
        #expect(try await store.search(query: "  \n ").isEmpty)
        #expect(try await store.search(query: "!!!").isEmpty)
    }

    @Test func searchTreatsOperatorsLiterally() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let withOr = makeHistoryEntry(raw: "alpha or beta", createdAt: fixedDate(0))
        let withoutOr = makeHistoryEntry(raw: "alpha beta", createdAt: fixedDate(10))
        try await store.save(withOr)
        try await store.save(withoutOr)

        // Raw FTS5 would parse OR as an operator and match both rows.
        // Sanitized, "OR" is a literal token that only the first row contains.
        let hits = try await store.search(query: "alpha OR beta")
        #expect(hits == [withOr])

        // Implicit AND across tokens still works.
        let both = try await store.search(query: "alpha beta")
        #expect(both == [withoutOr, withOr]) // newest first
    }

    @Test func updateKeepsFTSInSync() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        var entry = makeHistoryEntry(final: "original wording")
        try await store.save(entry)
        entry.finalText = "replacement phrasing"
        try await store.save(entry)

        #expect(try await store.search(query: "original").isEmpty)
        #expect(try await store.search(query: "replacement") == [entry])
    }

    @Test func deleteRemovesRowAndSearchHit() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let entry = makeHistoryEntry(raw: "ephemeral note")
        try await store.save(entry)
        try await store.delete(id: entry.id)

        #expect(try await store.recent(limit: 10).isEmpty)
        #expect(try await store.search(query: "ephemeral").isEmpty)
    }

    @Test func deleteAllEmptiesHistory() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        try await store.save(makeHistoryEntry(createdAt: fixedDate(0)))
        try await store.save(makeHistoryEntry(createdAt: fixedDate(1)))
        try await store.deleteAll()
        #expect(try await store.recent(limit: 10).isEmpty)
        #expect(try await store.search(query: "quick").isEmpty)
    }

    @Test func observationEmitsCurrentValue() async throws {
        let store = HistoryStore(database: try AppDatabase(inMemory: true))
        let entry = makeHistoryEntry()
        try await store.save(entry)
        var iterator = store.observeRecent(limit: 10).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == [entry])
    }
}

@Suite struct DictionaryStoreTests {
    @Test func upsertInsertsAndRoundTrips() async throws {
        let store = DictionaryStore(database: try AppDatabase(inMemory: true))
        let entry = DictionaryEntry(term: "WhisperKit", variants: ["whisper kit", "wisper kit"], createdAt: fixedDate())
        try await store.upsert(entry)
        let all = try await store.all()
        #expect(all == [entry]) // variants JSON + UUID round-trip
    }

    @Test func upsertIsCaseInsensitiveOnTerm() async throws {
        let store = DictionaryStore(database: try AppDatabase(inMemory: true))
        let original = DictionaryEntry(term: "SwiftUI", variants: [], createdAt: fixedDate())
        try await store.upsert(original)

        let replacement = DictionaryEntry(term: "swiftui", variants: ["swift ui"], createdAt: fixedDate(100))
        let stored = try await store.upsert(replacement)

        let all = try await store.all()
        #expect(all.count == 1)
        // Existing row updated in place: identity preserved, casing/variants adopted.
        #expect(stored.id == original.id)
        #expect(all[0].id == original.id)
        #expect(all[0].term == "swiftui")
        #expect(all[0].variants == ["swift ui"])
        #expect(all[0].createdAt == original.createdAt)
    }

    @Test func allTermsReturnsSortedTerms() async throws {
        let store = DictionaryStore(database: try AppDatabase(inMemory: true))
        try await store.upsert(DictionaryEntry(term: "zsh"))
        try await store.upsert(DictionaryEntry(term: "Anthropic"))
        try await store.upsert(DictionaryEntry(term: "grdb"))
        let terms = try await store.allTerms()
        #expect(terms == ["Anthropic", "grdb", "zsh"])
    }

    @Test func deleteRemovesEntry() async throws {
        let store = DictionaryStore(database: try AppDatabase(inMemory: true))
        let entry = DictionaryEntry(term: "Voxi")
        try await store.upsert(entry)
        try await store.delete(id: entry.id)
        #expect(try await store.all().isEmpty)
    }
}

@Suite struct CardStoreTests {
    @Test func insertFetchRoundTrip() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        let fetched = try await store.fetch(id: card.id)
        #expect(fetched == card) // includes UUID + all-field round-trip
    }

    @Test func fetchMissingReturnsNil() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        #expect(try await store.fetch(id: UUID()) == nil)
    }

    @Test func allNewestFirstOrders() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let old = makeCard(title: "old", createdAt: fixedDate(0))
        let new = makeCard(title: "new", createdAt: fixedDate(60))
        try await store.insert(old)
        try await store.insert(new)
        let all = try await store.allNewestFirst()
        #expect(all == [new, old])
    }

    @Test func fullLegalLifecycle() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)

        try await store.setStatus(id: card.id, to: .dispatched)
        var current = try #require(try await store.fetch(id: card.id))
        #expect(current.status == .dispatched)
        #expect(current.dispatchedAt != nil)

        try await store.setStatus(id: card.id, to: .running)
        try await store.setResult(id: card.id, exitCode: 0)
        current = try #require(try await store.fetch(id: card.id))
        #expect(current.status == .succeeded)
        #expect(current.exitCode == 0)
        #expect(current.finishedAt != nil)
    }

    @Test func nonZeroExitCodeFails() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        try await store.setStatus(id: card.id, to: .dispatched)
        try await store.setStatus(id: card.id, to: .running)
        try await store.setResult(id: card.id, exitCode: 1)
        let current = try #require(try await store.fetch(id: card.id))
        #expect(current.status == .failed)
        #expect(current.exitCode == 1)
    }

    @Test func illegalTransitionThrows() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)

        // queued -> running skips dispatched
        await #expect(throws: PersistenceError.illegalTransition(from: .queued, to: .running)) {
            try await store.setStatus(id: card.id, to: .running)
        }

        // succeeded is terminal
        try await store.setStatus(id: card.id, to: .dispatched)
        try await store.setStatus(id: card.id, to: .running)
        try await store.setResult(id: card.id, exitCode: 0)
        await #expect(throws: PersistenceError.illegalTransition(from: .succeeded, to: .queued)) {
            try await store.setStatus(id: card.id, to: .queued)
        }
        // and setResult on a terminal card throws too
        await #expect(throws: PersistenceError.illegalTransition(from: .succeeded, to: .succeeded)) {
            try await store.setResult(id: card.id, exitCode: 0)
        }
    }

    @Test func statusChangeOnMissingCardThrowsNotFound() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let ghost = UUID()
        await #expect(throws: PersistenceError.notFound(ghost)) {
            try await store.setStatus(id: ghost, to: .dispatched)
        }
    }

    @Test func requeueAfterFailureResetsRunState() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        try await store.setStatus(id: card.id, to: .dispatched)
        try await store.setStatus(id: card.id, to: .running)
        try await store.appendLog(id: card.id, chunk: "boom")
        try await store.setResult(id: card.id, exitCode: 7)

        try await store.setStatus(id: card.id, to: .queued)
        let current = try #require(try await store.fetch(id: card.id))
        #expect(current.status == .queued)
        #expect(current.log.isEmpty)
        #expect(current.exitCode == nil)
        #expect(current.dispatchedAt == nil)
        #expect(current.finishedAt == nil)
    }

    @Test func appendLogAppendsChunks() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        try await store.appendLog(id: card.id, chunk: "hello ")
        try await store.appendLog(id: card.id, chunk: "world")
        let current = try #require(try await store.fetch(id: card.id))
        #expect(current.log == "hello world")
    }

    @Test func appendLogOnMissingCardThrows() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let ghost = UUID()
        await #expect(throws: PersistenceError.notFound(ghost)) {
            try await store.appendLog(id: ghost, chunk: "x")
        }
    }

    @Test func reconcileInterruptedFailsInFlightCardsOnly() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let queued = makeCard(title: "queued")
        let dispatched = makeCard(title: "dispatched")
        let running = makeCard(title: "running")
        let succeeded = makeCard(title: "succeeded")
        for card in [queued, dispatched, running, succeeded] { try await store.insert(card) }

        try await store.setStatus(id: dispatched.id, to: .dispatched)
        try await store.setStatus(id: running.id, to: .dispatched)
        try await store.setStatus(id: running.id, to: .running)
        try await store.setStatus(id: succeeded.id, to: .dispatched)
        try await store.setStatus(id: succeeded.id, to: .running)
        try await store.setResult(id: succeeded.id, exitCode: 0)

        let reconciled = try await store.reconcileInterrupted()
        #expect(reconciled == 2)

        let q = try #require(try await store.fetch(id: queued.id))
        #expect(q.status == .queued)
        #expect(q.log.isEmpty)

        for id in [dispatched.id, running.id] {
            let card = try #require(try await store.fetch(id: id))
            #expect(card.status == .failed)
            #expect(card.finishedAt != nil)
            #expect(card.log.contains("in flight"))
        }

        let s = try #require(try await store.fetch(id: succeeded.id))
        #expect(s.status == .succeeded)
        #expect(!s.log.contains("in flight"))
    }

    @Test func deleteRemovesCard() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        try await store.delete(id: card.id)
        #expect(try await store.fetch(id: card.id) == nil)
    }

    @Test func observationEmitsCurrentValue() async throws {
        let store = CardStore(database: try AppDatabase(inMemory: true))
        let card = makeCard()
        try await store.insert(card)
        var iterator = store.observeAll().makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == [card])
    }
}
