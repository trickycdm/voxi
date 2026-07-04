import Foundation
import FluidAudio

/// FluidAudio Parakeet TDT 0.6B v3 (CoreML/ANE). Voxi's default engine:
/// better English WER than Whisper large-v3 at ~190x realtime.
///
/// This engine ships exactly one model (the fixed v3 CoreML repo), exposed
/// through the same catalog/download interface as multi-model engines.
actor ParakeetEngine: ASREngine {
    nonisolated let id = "parakeet"
    nonisolated let displayName = "Parakeet (FluidAudio)"

    /// The single model this engine offers. The ID doubles as the on-disk
    /// directory name, which MUST equal `Repo.parakeetV3.folderName` because
    /// FluidAudio's download/load/modelsExist all resolve the repo folder by
    /// appending that name to the parent of the directory they're given.
    static let modelID = "parakeet-tdt-0.6b-v3"
    static let modelDisplayName = "Parakeet TDT 0.6B v3"
    /// int8-encoder CoreML bundles + vocabulary, approximate.
    static let modelSizeMB = 600

    private nonisolated let modelsBase: URL
    private nonisolated var repoDir: URL {
        modelsBase.appendingPathComponent(Self.modelID, isDirectory: true)
    }

    private var manager: AsrManager?

    init(modelsBase: URL = VoxiPaths.modelsDir(engineID: "parakeet")) {
        self.modelsBase = modelsBase
    }

    func availableModels() async throws -> [ASRModelInfo] {
        [ASRModelInfo(
            id: Self.modelID,
            displayName: Self.modelDisplayName,
            sizeMB: Self.modelSizeMB,
            isDownloaded: AsrModels.modelsExist(at: repoDir, version: .v3),
            isRecommended: true)]
    }

    func downloadModel(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard modelID == Self.modelID else {
            throw ASREngineError.downloadFailed("Unknown Parakeet model \(modelID)")
        }
        do {
            _ = try await AsrModels.download(to: repoDir, version: .v3) { update in
                progress(update.fractionCompleted)
            }
        } catch {
            throw ASREngineError.downloadFailed(String(describing: error))
        }
    }

    func deleteModel(_ modelID: String) async throws {
        guard modelID == Self.modelID else { return }
        await unload()
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
    }

    func load(modelID: String) async throws {
        guard modelID == Self.modelID, AsrModels.modelsExist(at: repoDir, version: .v3) else {
            throw ASREngineError.modelNotDownloaded(modelID)
        }
        if manager != nil { return }
        do {
            let models = try await AsrModels.load(from: repoDir, version: .v3)
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            manager = mgr
        } catch {
            manager = nil
            throw ASREngineError.transcriptionFailed("Parakeet failed to load: \(error)")
        }
    }

    func unload() async {
        manager = nil
    }

    var isLoaded: Bool { manager != nil }

    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> String {
        guard let manager else { throw ASREngineError.notLoaded }
        // Vocabulary hints are not fed to the decoder; dictionary spelling is
        // enforced downstream by the refiner. The language hint maps to
        // FluidAudio's script-aware token filter where supported.
        let language = hints.language.flatMap { Language(rawValue: $0) }
        do {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state, language: language)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ASREngineError.transcriptionFailed(String(describing: error))
        }
    }
}
