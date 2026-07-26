import Foundation
import Testing
@testable import Voxi

private func entry(_ text: String, raw: String? = nil) -> HistoryEntry {
    HistoryEntry(
        rawTranscript: raw ?? text,
        finalText: text,
        engineID: "parakeet",
        modelID: "p-v3"
    )
}

@MainActor
@Suite struct HubHistoryModelTests {
    private let store: HistoryStore
    private let model: HistoryModel

    init() throws {
        let database = try AppDatabase(inMemory: true)
        store = HistoryStore(database: database)
        model = HistoryModel(store: store)
    }

    @Test func emptyQueryShowsRecent() async throws {
        try await store.save(entry("The quick brown fox."))
        try await store.save(entry("Ship the report to Sarah."))

        model.searchText = ""
        #expect(model.mode == .recent)

        await model.loadRecentOnce()
        #expect(model.displayed.count == 2)
        // Newest first.
        #expect(model.displayed.first?.finalText == "Ship the report to Sarah.")
    }

    @Test func searchableQuerySwitchesToSearchResults() async throws {
        try await store.save(entry("The quick brown fox."))
        try await store.save(entry("Ship the report to Sarah."))
        await model.loadRecentOnce()

        model.searchText = "sarah"
        #expect(model.mode == .search(query: "sarah"))

        await model.searchNow()
        #expect(model.displayed.map(\.finalText) == ["Ship the report to Sarah."])

        // Clearing the query flips back to the recent list without a new fetch.
        model.searchText = ""
        #expect(model.displayed.count == 2)
    }

    @Test func unsearchableQueryFallsBackToRecent() async throws {
        try await store.save(entry("Hello world."))
        await model.loadRecentOnce()

        model.searchText = "   "
        #expect(model.mode == .recent)
        await model.searchNow()
        #expect(model.displayed.count == 1)
    }

    @Test func deleteRemovesFromStoreAndSearchResults() async throws {
        try await store.save(entry("Alpha note about GRDB."))
        try await store.save(entry("Beta note about GRDB."))

        model.searchText = "grdb"
        await model.searchNow()
        #expect(model.searchResults.count == 2)

        let victim = try #require(model.searchResults.first)
        await model.delete(victim)
        #expect(model.searchResults.count == 1)
        #expect(try await store.recent(limit: 10).count == 1)
    }

    @Test func clearAllEmptiesHistory() async throws {
        try await store.save(entry("One."))
        try await store.save(entry("Two."))
        model.searchText = "one"
        await model.searchNow()

        await model.clearAll()
        #expect(model.searchResults.isEmpty)
        #expect(try await store.recent(limit: 10).isEmpty)
    }
}

@MainActor
@Suite struct HubDictionaryModelTests {
    private let store: DictionaryStore
    private let learnedStore: LearnedCorrectionStore
    private let model: DictionaryModel

    init() throws {
        let database = try AppDatabase(inMemory: true)
        store = DictionaryStore(database: database)
        learnedStore = LearnedCorrectionStore(database: database)
        model = DictionaryModel(store: store, learnedStore: learnedStore)
    }

    @Test func rejectsEmptyTerm() async throws {
        #expect(await model.save(term: "   ", variantsCSV: "x") == false)
        #expect(model.entries.isEmpty)
    }

    @Test func savesTermWithParsedVariants() async throws {
        #expect(await model.save(term: " GRDB ", variantsCSV: "gee are dee bee, grdb, ") == true)
        #expect(model.entries.count == 1)
        let saved = try #require(model.entries.first)
        #expect(saved.term == "GRDB")
        #expect(saved.variants == ["gee are dee bee", "grdb"])
    }

    @Test func editingRenamesWithoutLeavingOldRow() async throws {
        await model.save(term: "Xcode", variantsCSV: "ex code")
        let original = try #require(model.entries.first)

        #expect(await model.save(term: "XcodeGen", variantsCSV: "ex code gen", replacing: original) == true)
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.term == "XcodeGen")
        #expect(model.entries.first?.variants == ["ex code gen"])
    }

    @Test func editingSameTermUpdatesVariantsInPlace() async throws {
        await model.save(term: "Voxi", variantsCSV: "voxie")
        let original = try #require(model.entries.first)

        #expect(await model.save(term: "voxi", variantsCSV: "voxie, foxy", replacing: original) == true)
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.id == original.id)
        #expect(model.entries.first?.variants == ["voxie", "foxy"])
    }

    @Test func deleteRemovesEntry() async throws {
        await model.save(term: "GRDB", variantsCSV: "")
        let saved = try #require(model.entries.first)
        await model.delete(saved)
        #expect(model.entries.isEmpty)
    }

    @Test func loadPopulatesLearnedCorrections() async throws {
        try await learnedStore.upsert(LearnedCorrection(wrong: "Jordn", right: "Jordan"))
        await model.load()
        #expect(model.learned.map(\.right) == ["Jordan"])
    }

    @Test func unlearnRemovesPairAndStripsVariant() async throws {
        // Mirror what post-insert learning stores: entry + log row.
        try await store.upsert(DictionaryEntry(term: "Jordan", variants: ["Jordn", "manual variant"]))
        let correction = LearnedCorrection(wrong: "jordn", right: "jordan")
        try await learnedStore.upsert(correction)
        await model.load()

        await model.unlearn(correction)

        #expect(model.learned.isEmpty)
        // Only the learned variant is stripped; the term and its other
        // variants survive.
        let entry = try #require(model.entries.first)
        #expect(entry.term == "Jordan")
        #expect(entry.variants == ["manual variant"])
    }

    @Test func unlearnLastVariantKeepsBareTerm() async throws {
        try await store.upsert(DictionaryEntry(term: "Voxi", variants: ["Voxy"]))
        let correction = LearnedCorrection(wrong: "Voxy", right: "Voxi")
        try await learnedStore.upsert(correction)
        await model.load()

        await model.unlearn(correction)

        #expect(model.entries.first?.term == "Voxi")
        #expect(model.entries.first?.variants.isEmpty == true)
    }

    @Test func unlearnWithoutMatchingEntryStillRemovesPair() async throws {
        let correction = LearnedCorrection(wrong: "Jordn", right: "Jordan")
        try await learnedStore.upsert(correction)
        await model.load()

        await model.unlearn(correction)

        #expect(model.learned.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func deleteEntryAlsoDropsItsLearnedPairs() async throws {
        try await store.upsert(DictionaryEntry(term: "Jordan", variants: ["Jordn"]))
        try await learnedStore.upsert(LearnedCorrection(wrong: "Jordn", right: "jordan"))
        try await learnedStore.upsert(LearnedCorrection(wrong: "Voxy", right: "Voxi"))
        await model.load()
        let entry = try #require(model.entries.first)

        await model.delete(entry)

        #expect(model.entries.isEmpty)
        // Pairs enforced through the deleted entry go with it; others stay.
        #expect(model.learned.map(\.right) == ["Voxi"])
    }
}
