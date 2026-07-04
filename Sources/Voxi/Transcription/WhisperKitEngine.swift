import Foundation
import WhisperKit

/// WhisperKit-backed engine (CoreML/ANE Whisper variants). Covers long-tail
/// languages; the default engine for English dictation is `ParakeetEngine`.
actor WhisperKitEngine: ASREngine {
    nonisolated let id = "whisperkit"
    nonisolated let displayName = "Whisper (WhisperKit)"

    /// All model + tokenizer files live under Application Support/Voxi/Models/whisperkit.
    private nonisolated let modelsBase: URL
    private nonisolated var tokenizerFolder: URL {
        modelsBase.appendingPathComponent("tokenizers", isDirectory: true)
    }

    /// WhisperKit is documented as not-yet-Sendable but safe under serial access;
    /// this actor is that serial context. `nonisolated(unsafe)` opts the stored
    /// pipeline out of region checks that would otherwise reject calling its
    /// nonisolated-async methods from actor isolation.
    private nonisolated(unsafe) var pipe: WhisperKit?
    private var loadedModelID: String?

    init(modelsBase: URL = VoxiPaths.modelsDir(engineID: "whisperkit")) {
        self.modelsBase = modelsBase
    }

    func availableModels() async throws -> [ASRModelInfo] {
        WhisperKitCatalog.merged(
            curated: WhisperKitCatalog.curated,
            downloadedIDs: WhisperKitCatalog.downloadedVariants(under: modelsBase))
    }

    func downloadModel(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            _ = try await WhisperKit.download(
                variant: modelID,
                downloadBase: modelsBase,
                useBackgroundSession: false,
                from: WhisperKitCatalog.modelRepo,
                progressCallback: { progress($0.fractionCompleted) }
            )
        } catch {
            throw ASREngineError.downloadFailed(String(describing: error))
        }
    }

    func deleteModel(_ modelID: String) async throws {
        if loadedModelID == modelID {
            await unload()
        }
        let folder = WhisperKitCatalog.variantFolder(under: modelsBase, modelID: modelID)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func load(modelID: String) async throws {
        let folder = WhisperKitCatalog.variantFolder(under: modelsBase, modelID: modelID)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ASREngineError.modelNotDownloaded(modelID)
        }
        if loadedModelID == modelID, pipe != nil { return }
        await unload()

        // modelFolder points at the already-downloaded variant so the model is
        // never re-fetched; download stays true because the tokenizer downloads
        // separately (into tokenizerFolder) on first load of a variant family.
        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: modelsBase,
            modelRepo: WhisperKitCatalog.modelRepo,
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        do {
            pipe = try await WhisperKit(config)
            loadedModelID = modelID
        } catch {
            pipe = nil
            loadedModelID = nil
            throw ASREngineError.transcriptionFailed("WhisperKit failed to load \(modelID): \(error)")
        }
    }

    func unload() async {
        if let pipe {
            await pipe.unloadModels()
        }
        pipe = nil
        loadedModelID = nil
    }

    var isLoaded: Bool { pipe != nil }

    func transcribe(samples: [Float], hints: TranscriptionHints) async throws -> String {
        guard let pipe else { throw ASREngineError.notLoaded }
        // hints.vocabulary is deliberately not fed via promptTokens: prompt
        // conditioning biases Whisper toward continuing the prompt's style and
        // can leak prompt words into output. Dictionary spelling is enforced
        // downstream by the refiner instead.
        let options = DecodingOptions(
            task: .transcribe,
            language: hints.language,
            temperature: 0,
            chunkingStrategy: .vad
        )
        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ASREngineError.transcriptionFailed(String(describing: error))
        }
    }
}
