import Foundation

/// Owns the set of registered ASR engines, the persisted engine/model
/// selection, and the invariant that at most one engine holds models in
/// memory at a time.
@MainActor
final class ASREngineRegistry {
    nonisolated static let defaultEngineID = "parakeet"

    /// UserDefaults keys, exposed so Settings UI can bind @AppStorage to them.
    nonisolated static let engineDefaultsKey = "asr.selectedEngineID"
    nonisolated static func modelDefaultsKey(engineID: String) -> String { "asr.selectedModelID.\(engineID)" }

    /// Registration order = display order.
    let engines: [any ASREngine]
    private let enginesByID: [String: any ASREngine]
    private let defaults: UserDefaults
    private(set) var loadedEngineID: String?

    /// The production engine set. New engines: append here, nothing else.
    static func makeDefaultEngines() -> [any ASREngine] {
        [ParakeetEngine(), WhisperKitEngine()]
    }

    init(engines: [any ASREngine], defaults: UserDefaults = .standard) {
        precondition(!engines.isEmpty, "registry needs at least one engine")
        self.engines = engines
        self.enginesByID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        self.defaults = defaults
    }

    func engine(withID id: String) -> (any ASREngine)? {
        enginesByID[id]
    }

    /// Persisted selection; falls back to the default engine, then to the
    /// first registered engine, when the stored value is missing or stale.
    var selectedEngineID: String {
        get {
            if let stored = defaults.string(forKey: Self.engineDefaultsKey), enginesByID[stored] != nil {
                return stored
            }
            return enginesByID[Self.defaultEngineID] != nil ? Self.defaultEngineID : engines[0].id
        }
        set {
            guard enginesByID[newValue] != nil else { return }
            defaults.set(newValue, forKey: Self.engineDefaultsKey)
        }
    }

    var selectedEngine: any ASREngine {
        // selectedEngineID only ever returns a registered ID.
        enginesByID[selectedEngineID]!
    }

    /// Stored model choice for an engine, nil when the user never picked one.
    func selectedModelID(for engineID: String) -> String? {
        defaults.string(forKey: Self.modelDefaultsKey(engineID: engineID))
    }

    func setSelectedModel(_ modelID: String, for engineID: String) {
        defaults.set(modelID, forKey: Self.modelDefaultsKey(engineID: engineID))
    }

    /// The model that would be loaded for an engine right now: the stored
    /// choice, else the engine's recommended model, else its first model.
    func resolvedModelID(for engine: any ASREngine) async throws -> String {
        if let stored = selectedModelID(for: engine.id) {
            return stored
        }
        let models = try await engine.availableModels()
        guard let pick = models.first(where: \.isRecommended) ?? models.first else {
            throw ASREngineError.modelNotDownloaded("<no models for \(engine.id)>")
        }
        return pick.id
    }

    /// Load the selected engine + model, unloading any previously loaded
    /// engine first. Throws `.modelNotDownloaded` rather than downloading;
    /// callers own download UX (Settings, CLI).
    @discardableResult
    func loadSelected() async throws -> any ASREngine {
        let engineID = selectedEngineID
        let engine = enginesByID[engineID]!
        let modelID = try await resolvedModelID(for: engine)

        if let previousID = loadedEngineID, previousID != engineID,
           let previous = enginesByID[previousID] {
            await previous.unload()
            loadedEngineID = nil
        }
        try await engine.load(modelID: modelID)
        loadedEngineID = engineID
        return engine
    }

    func unloadAll() async {
        for engine in engines {
            await engine.unload()
        }
        loadedEngineID = nil
    }
}
