import Foundation

/// Curated WhisperKit model catalog + on-disk discovery. Pure logic, separated
/// from `WhisperKitEngine` so merging can be unit-tested against a mock file layout.
enum WhisperKitCatalog {
    /// HuggingFace repo WhisperKit downloads variants from.
    static let modelRepo = "argmaxinc/whisperkit-coreml"

    /// Curated variants shown even before anything is downloaded.
    /// Sizes are approximate on-disk footprints of the CoreML bundles.
    static let curated: [ASRModelInfo] = [
        ASRModelInfo(
            id: "openai_whisper-tiny",
            displayName: "Whisper Tiny",
            sizeMB: 150, isDownloaded: false),
        ASRModelInfo(
            id: "openai_whisper-base",
            displayName: "Whisper Base",
            sizeMB: 290, isDownloaded: false),
        ASRModelInfo(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            sizeMB: 950, isDownloaded: false),
        ASRModelInfo(
            id: "distil-whisper_distil-large-v3_594MB",
            displayName: "Distil Whisper Large v3 (quantized)",
            sizeMB: 594, isDownloaded: false),
        ASRModelInfo(
            id: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "Whisper Large v3 Turbo (quantized)",
            sizeMB: 626, isDownloaded: false, isRecommended: true),
    ]

    /// Where `WhisperKit.download(variant:downloadBase:)` places variant folders:
    /// `<base>/models/<repo>/<variant>/`.
    static func variantsRoot(under base: URL) -> URL {
        base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepo, isDirectory: true)
    }

    static func variantFolder(under base: URL, modelID: String) -> URL {
        variantsRoot(under: base).appendingPathComponent(modelID, isDirectory: true)
    }

    /// Variant IDs that exist on disk (non-empty directories under the variants root).
    static func downloadedVariants(under base: URL, fileManager: FileManager = .default) -> Set<String> {
        let root = variantsRoot(under: base)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var ids: Set<String> = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let contents = (try? fileManager.contentsOfDirectory(atPath: entry.path)) ?? []
            if !contents.isEmpty {
                ids.insert(entry.lastPathComponent)
            }
        }
        return ids
    }

    /// Curated catalog with download state applied, plus any on-disk variants
    /// that aren't in the curated list (dropped-in models are first-class).
    static func merged(curated: [ASRModelInfo], downloadedIDs: Set<String>) -> [ASRModelInfo] {
        var models = curated.map { model in
            var m = model
            m.isDownloaded = downloadedIDs.contains(model.id)
            return m
        }
        let curatedIDs = Set(curated.map(\.id))
        let extras = downloadedIDs.subtracting(curatedIDs).sorted()
        models.append(contentsOf: extras.map {
            ASRModelInfo(id: $0, displayName: $0, sizeMB: nil, isDownloaded: true)
        })
        return models
    }
}
