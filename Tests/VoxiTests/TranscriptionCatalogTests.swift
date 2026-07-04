import Foundation
import Testing
@testable import Voxi

@Suite struct TranscriptionCatalogTests {
    @Test func curatedCatalogIsSane() {
        let curated = WhisperKitCatalog.curated
        #expect(!curated.isEmpty)
        #expect(Set(curated.map(\.id)).count == curated.count, "model IDs must be unique")
        #expect(curated.filter(\.isRecommended).count == 1, "exactly one recommended model")
        #expect(curated.allSatisfy { ($0.sizeMB ?? 0) > 0 }, "curated entries carry approximate sizes")
        #expect(curated.allSatisfy { !$0.isDownloaded }, "curated template starts not-downloaded")
        #expect(curated.contains { $0.id == "openai_whisper-large-v3-v20240930_626MB" && $0.isRecommended })
    }

    @Test func downloadedVariantsScansOnlyNonEmptyDirectories() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let root = WhisperKitCatalog.variantsRoot(under: base)
        let tiny = root.appendingPathComponent("openai_whisper-tiny")
        let empty = root.appendingPathComponent("openai_whisper-base")
        let custom = root.appendingPathComponent("somebody_custom-model")
        for dir in [tiny, empty, custom] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: tiny.appendingPathComponent("config.json"))
        try Data("x".utf8).write(to: custom.appendingPathComponent("config.json"))
        // A stray file at the root must not be treated as a variant.
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let ids = WhisperKitCatalog.downloadedVariants(under: base)
        #expect(ids == ["openai_whisper-tiny", "somebody_custom-model"])
    }

    @Test func downloadedVariantsOfMissingRootIsEmpty() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-catalog-missing-\(UUID().uuidString)")
        #expect(WhisperKitCatalog.downloadedVariants(under: base).isEmpty)
    }

    @Test func mergedMarksCuratedAndAppendsOnDiskExtras() {
        let merged = WhisperKitCatalog.merged(
            curated: WhisperKitCatalog.curated,
            downloadedIDs: ["openai_whisper-tiny", "somebody_custom-model", "another_custom"])

        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        #expect(byID["openai_whisper-tiny"]?.isDownloaded == true)
        #expect(byID["openai_whisper-base"]?.isDownloaded == false)

        // Curated entries keep their order and lead the list.
        #expect(Array(merged.prefix(WhisperKitCatalog.curated.count).map(\.id))
            == WhisperKitCatalog.curated.map(\.id))

        // Dropped-in models appear, downloaded, sorted, without invented sizes.
        let extras = merged.suffix(from: WhisperKitCatalog.curated.count)
        #expect(extras.map(\.id) == ["another_custom", "somebody_custom-model"])
        #expect(extras.allSatisfy { $0.isDownloaded && $0.sizeMB == nil && !$0.isRecommended })
    }

    @Test func mergedWithNothingOnDiskIsCurated() {
        let merged = WhisperKitCatalog.merged(curated: WhisperKitCatalog.curated, downloadedIDs: [])
        #expect(merged.map(\.id) == WhisperKitCatalog.curated.map(\.id))
        #expect(merged.allSatisfy { !$0.isDownloaded })
    }
}
