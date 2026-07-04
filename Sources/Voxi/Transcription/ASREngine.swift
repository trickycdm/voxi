import Foundation

/// A downloadable/installed model within an ASR engine.
struct ASRModelInfo: Identifiable, Hashable, Sendable {
    /// Engine-scoped identifier (e.g. "openai_whisper-large-v3-v20240930_626MB").
    let id: String
    let displayName: String
    /// Approximate download size in MB, if known before download.
    let sizeMB: Int?
    var isDownloaded: Bool
    /// True if the engine recommends this model for the current machine.
    var isRecommended: Bool = false
}

/// Extra context passed to transcription.
struct TranscriptionHints: Sendable {
    /// BCP-47-ish language code, nil = auto.
    var language: String? = "en"
    /// Personal-dictionary terms to bias recognition/spelling toward.
    var vocabulary: [String] = []
}

enum ASREngineError: Error, LocalizedError {
    case modelNotDownloaded(String)
    case notLoaded
    case downloadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let m): "Model \(m) is not downloaded"
        case .notLoaded: "No model loaded"
        case .downloadFailed(let why): "Model download failed: \(why)"
        case .transcriptionFailed(let why): "Transcription failed: \(why)"
        }
    }
}

/// A pluggable on-device speech-to-text engine. Adding a new engine means
/// implementing this protocol and registering it in `ASREngineRegistry` — nothing else.
///
/// Audio contract: 16 kHz mono Float32 samples.
protocol ASREngine: AnyObject, Sendable {
    /// Stable identifier, also used as the on-disk models subdirectory name.
    var id: String { get }
    var displayName: String { get }

    /// All models this engine knows about (remote catalog merged with what's on disk).
    func availableModels() async throws -> [ASRModelInfo]

    /// Download a model into `VoxiPaths.modelsDir(engineID:)`, reporting 0...1 progress.
    func downloadModel(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws

    func deleteModel(_ modelID: String) async throws

    /// Load a downloaded model into memory. Throws `.modelNotDownloaded` if missing.
    func load(modelID: String) async throws

    func unload() async

    var isLoaded: Bool { get async }

    /// Transcribe a complete utterance. 16 kHz mono Float32.
    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> String
}
