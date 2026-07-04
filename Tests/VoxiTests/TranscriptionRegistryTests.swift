import Foundation
import Testing
@testable import Voxi

/// In-memory ASREngine double for registry tests. No model downloads.
private actor MockEngine: ASREngine {
    nonisolated let id: String
    nonisolated let displayName: String

    private var models: [ASRModelInfo]
    private(set) var loadedModelID: String?
    private(set) var unloadCount = 0

    init(id: String, models: [ASRModelInfo]) {
        self.id = id
        self.displayName = id
        self.models = models
    }

    func availableModels() async throws -> [ASRModelInfo] { models }

    func downloadModel(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else {
            throw ASREngineError.downloadFailed("unknown \(modelID)")
        }
        progress(1)
        models[index].isDownloaded = true
    }

    func deleteModel(_ modelID: String) async throws {
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].isDownloaded = false
        }
    }

    func load(modelID: String) async throws {
        guard models.first(where: { $0.id == modelID })?.isDownloaded == true else {
            throw ASREngineError.modelNotDownloaded(modelID)
        }
        loadedModelID = modelID
    }

    func unload() async {
        loadedModelID = nil
        unloadCount += 1
    }

    var isLoaded: Bool { loadedModelID != nil }

    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> String {
        guard loadedModelID != nil else { throw ASREngineError.notLoaded }
        return "mock transcript"
    }
}

private func model(_ id: String, downloaded: Bool = false, recommended: Bool = false) -> ASRModelInfo {
    ASRModelInfo(id: id, displayName: id, sizeMB: 1, isDownloaded: downloaded, isRecommended: recommended)
}

@MainActor
@Suite struct TranscriptionRegistryTests {
    private let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "voxi-registry-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func makeRegistry(
        parakeetModels: [ASRModelInfo] = [model("p-model", downloaded: true, recommended: true)],
        whisperModels: [ASRModelInfo] = [
            model("w-tiny", downloaded: true),
            model("w-large", downloaded: true, recommended: true),
        ]
    ) -> (ASREngineRegistry, MockEngine, MockEngine) {
        let parakeet = MockEngine(id: "parakeet", models: parakeetModels)
        let whisper = MockEngine(id: "whisperkit", models: whisperModels)
        let registry = ASREngineRegistry(engines: [parakeet, whisper], defaults: defaults)
        return (registry, parakeet, whisper)
    }

    @Test func defaultSelectionIsParakeet() {
        let (registry, _, _) = makeRegistry()
        #expect(registry.selectedEngineID == "parakeet")
        #expect(registry.selectedEngine.id == "parakeet")
    }

    @Test func selectionPersistsAcrossRegistryInstances() {
        let (registry, _, _) = makeRegistry()
        registry.selectedEngineID = "whisperkit"
        #expect(registry.selectedEngineID == "whisperkit")

        let (rebuilt, _, _) = makeRegistry()
        #expect(rebuilt.selectedEngineID == "whisperkit")
    }

    @Test func unknownSelectionIsIgnored() {
        let (registry, _, _) = makeRegistry()
        registry.selectedEngineID = "whisperkit"
        registry.selectedEngineID = "no-such-engine"
        #expect(registry.selectedEngineID == "whisperkit")
    }

    @Test func staleStoredEngineFallsBackToDefault() {
        defaults.set("engine-removed-in-an-update", forKey: ASREngineRegistry.engineDefaultsKey)
        let (registry, _, _) = makeRegistry()
        #expect(registry.selectedEngineID == "parakeet")
    }

    @Test func fallsBackToFirstEngineWhenDefaultUnregistered() {
        let whisper = MockEngine(id: "whisperkit", models: [model("w-tiny", downloaded: true)])
        let registry = ASREngineRegistry(engines: [whisper], defaults: defaults)
        #expect(registry.selectedEngineID == "whisperkit")
    }

    @Test func modelSelectionIsPerEngineAndPersisted() {
        let (registry, _, _) = makeRegistry()
        registry.setSelectedModel("w-tiny", for: "whisperkit")
        #expect(registry.selectedModelID(for: "whisperkit") == "w-tiny")
        #expect(registry.selectedModelID(for: "parakeet") == nil)

        let (rebuilt, _, _) = makeRegistry()
        #expect(rebuilt.selectedModelID(for: "whisperkit") == "w-tiny")
    }

    @Test func resolvedModelPrefersStoredThenRecommendedThenFirst() async throws {
        let (registry, parakeet, whisper) = makeRegistry()

        // Recommended wins when nothing is stored.
        #expect(try await registry.resolvedModelID(for: whisper) == "w-large")
        // Stored choice wins over recommended.
        registry.setSelectedModel("w-tiny", for: "whisperkit")
        #expect(try await registry.resolvedModelID(for: whisper) == "w-tiny")
        // Single-model engine resolves to its recommended model.
        #expect(try await registry.resolvedModelID(for: parakeet) == "p-model")

        // No recommended flag: first model wins.
        let bare = MockEngine(id: "bare", models: [model("first"), model("second")])
        #expect(try await registry.resolvedModelID(for: bare) == "first")
    }

    @Test func loadSelectedLoadsResolvedModel() async throws {
        let (registry, parakeet, _) = makeRegistry()
        let engine = try await registry.loadSelected()
        #expect(engine.id == "parakeet")
        #expect(registry.loadedEngineID == "parakeet")
        #expect(await parakeet.loadedModelID == "p-model")
    }

    @Test func switchingEnginesUnloadsThePreviousOne() async throws {
        let (registry, parakeet, whisper) = makeRegistry()
        try await registry.loadSelected()
        #expect(await parakeet.isLoaded)

        registry.selectedEngineID = "whisperkit"
        try await registry.loadSelected()
        #expect(registry.loadedEngineID == "whisperkit")
        #expect(await whisper.isLoaded)
        #expect(await !parakeet.isLoaded)
        #expect(await parakeet.unloadCount == 1)
    }

    @Test func reloadingSameEngineDoesNotUnloadIt() async throws {
        let (registry, parakeet, _) = makeRegistry()
        try await registry.loadSelected()
        try await registry.loadSelected()
        #expect(await parakeet.unloadCount == 0)
        #expect(await parakeet.isLoaded)
    }

    @Test func loadSelectedThrowsWhenModelNotDownloaded() async throws {
        let (registry, _, _) = makeRegistry(
            parakeetModels: [model("p-model", downloaded: false, recommended: true)])
        await #expect(throws: ASREngineError.self) {
            try await registry.loadSelected()
        }
        #expect(registry.loadedEngineID == nil)
    }

    @Test func unloadAllUnloadsEverythingAndClearsState() async throws {
        let (registry, parakeet, whisper) = makeRegistry()
        try await registry.loadSelected()
        await registry.unloadAll()
        #expect(registry.loadedEngineID == nil)
        #expect(await !parakeet.isLoaded)
        #expect(await whisper.unloadCount == 1)
    }
}
