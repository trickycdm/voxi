import Foundation
import Testing
@testable import Voxi

/// In-memory ASREngine double for SpeechModel tests.
private actor HubMockEngine: ASREngine {
    nonisolated let id: String
    nonisolated let displayName: String
    private var models: [ASRModelInfo]

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
        progress(0.5)
        progress(1)
        models[index].isDownloaded = true
    }

    func deleteModel(_ modelID: String) async throws {
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].isDownloaded = false
        }
    }

    func load(modelID: String) async throws {}
    func unload() async {}
    var isLoaded: Bool { false }

    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> String {
        "mock"
    }
}

@MainActor
@Suite struct HubSettingsModelsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "voxi.tests.hub-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    // MARK: Insertion settings

    @Test func insertionSettingsRoundTripAndApply() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var applied: [InsertionSettings] = []
        let model = InsertionSettingsModel(defaults: defaults)
        model.apply = { applied.append($0) }

        model.settings.method = .pasteboardAlways
        model.settings.restoreClipboard = false

        #expect(applied.count == 2)
        #expect(applied.last?.method == .pasteboardAlways)

        let reloaded = InsertionSettingsModel(defaults: defaults)
        #expect(reloaded.settings == model.settings)
        #expect(reloaded.settings.restoreClipboard == false)
    }

    // MARK: Microphone device selection

    @Test func microphoneSelectionPersistsToCoordinatorKey() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = MicrophoneModel(defaults: defaults, listDevices: { [] })
        #expect(model.selectedUID == nil)

        model.selectedUID = "usb-mic-123"
        #expect(defaults.string(forKey: "audio.inputDeviceUID") == "usb-mic-123")
        #expect(MicrophoneModel(defaults: defaults, listDevices: { [] }).selectedUID == "usb-mic-123")

        model.selectedUID = nil
        #expect(defaults.string(forKey: "audio.inputDeviceUID") == nil)
    }

    @Test func microphoneActiveNameHandlesMissingDevice() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let devices = [
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
            AudioInputDevice(id: "usb-1", name: "USB Mic", isDefault: false),
        ]
        let model = MicrophoneModel(defaults: defaults, listDevices: { devices })
        model.refreshDevices()

        #expect(model.activeDeviceName == "MacBook Pro Microphone")
        model.selectedUID = "usb-1"
        #expect(model.activeDeviceName == "USB Mic")
        #expect(!model.selectionUnavailable)

        model.selectedUID = "gone-device"
        #expect(model.selectionUnavailable)
        #expect(model.activeDeviceName.contains("unavailable"))
    }

    // MARK: Refinement config editing

    @Test func refinementConfigSaveRoundTripAndDirtyTracking() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RefinementModel(defaults: defaults)
        #expect(!model.isDirty)

        model.config.backend = .anthropic
        model.config.anthropicAPIKey = "sk-ant-test"
        #expect(model.isDirty)

        model.save()
        #expect(!model.isDirty)
        #expect(RefinementModel(defaults: defaults).config == model.config)
    }

    @Test func refinementTestConnectionRulesAlwaysOK() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RefinementModel(defaults: defaults)
        await model.testConnection()
        guard case .ok = model.testState else {
            Issue.record("expected .ok for rules backend, got \(model.testState)")
            return
        }
    }

    @Test func refinementTestConnectionFailsOnIncompleteConfig() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RefinementModel(defaults: defaults)
        model.config.backend = .anthropic
        model.config.anthropicAPIKey = ""
        await model.testConnection()
        guard case .failed = model.testState else {
            Issue.record("expected .failed for missing API key, got \(model.testState)")
            return
        }
    }

    // MARK: Speech engine/model management

    private func makeSpeech(defaults: UserDefaults) -> (SpeechModel, ASREngineRegistry) {
        let parakeet = HubMockEngine(id: "parakeet", models: [
            ASRModelInfo(id: "p-v3", displayName: "Parakeet v3", sizeMB: 600,
                         isDownloaded: false, isRecommended: true),
        ])
        let whisper = HubMockEngine(id: "whisperkit", models: [
            ASRModelInfo(id: "w-large", displayName: "Whisper Large", sizeMB: 1536,
                         isDownloaded: true, isRecommended: true),
            ASRModelInfo(id: "w-tiny", displayName: "Whisper Tiny", sizeMB: 80,
                         isDownloaded: false),
        ])
        let registry = ASREngineRegistry(engines: [parakeet, whisper], defaults: defaults)
        return (SpeechModel(registry: registry), registry)
    }

    @Test func speechModelListsSelectsDownloadsAndDeletes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let (model, registry) = makeSpeech(defaults: defaults)
        #expect(model.selectedEngineID == "parakeet")

        await model.loadModels()
        #expect(model.models.map(\.id) == ["p-v3"])

        // Download reports progress, then refreshes the downloaded state.
        await model.download("p-v3")
        #expect(model.downloadProgress["p-v3"] == nil)
        #expect(model.models.first?.isDownloaded == true)
        #expect(model.errorMessage == nil)

        model.select("p-v3")
        #expect(registry.selectedModelID(for: "parakeet") == "p-v3")
        #expect(model.selectedModelID == "p-v3")

        await model.delete("p-v3")
        #expect(model.models.first?.isDownloaded == false)
    }

    @Test func speechEngineSwitchPersistsAndReloadsCatalog() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let (model, registry) = makeSpeech(defaults: defaults)
        model.selectedEngineID = "whisperkit"
        #expect(registry.selectedEngineID == "whisperkit")

        await model.loadModels()
        #expect(Set(model.models.map(\.id)) == ["w-large", "w-tiny"])
    }

    @Test func speechDownloadFailureSurfacesError() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let (model, _) = makeSpeech(defaults: defaults)
        await model.loadModels()
        await model.download("nonexistent-model")
        #expect(model.errorMessage?.contains("Download failed") == true)
        #expect(model.downloadProgress["nonexistent-model"] == nil)
    }
}
