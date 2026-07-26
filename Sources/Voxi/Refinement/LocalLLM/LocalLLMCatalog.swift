import CryptoKit
import Foundation

/// One downloadable GGUF model for the on-device refiner.
///
/// `url` is a pinned Hugging Face revision URL (`…/resolve/<commit>/<file>`),
/// never a branch, so a download is reproducible and the recorded hash stays
/// valid. Descriptor values (URL, SHA-256, byte count) are lifted from
/// ghost-pepper (MIT, github.com/matthartman/ghost-pepper), which ships the
/// same models.
struct GGUFModelDescriptor: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let fileName: String
    let sizeMB: Int
    let url: String
    let expectedSHA256: String
    let expectedByteCount: Int64
    let maxTokenCount: Int32
    let isRecommended: Bool
}

/// Curated GGUF models + on-disk state checks. Pure logic apart from
/// filesystem reads; every function takes the models directory explicitly so
/// tests can point it at a temp dir (same shape as `WhisperKitCatalog`).
enum LocalLLMCatalog {
    /// Directory key under Application Support/Voxi/Models/.
    static let engineID = "local-llm"

    // Empirical (2026-07-26, M4 Pro): the 0.8B at suppressed thinking only
    // does light punctuation cleanup — it parrots fillers and ignores
    // "scratch that" even with the few-shots in context. The 2B does real
    // cleanup at 0.5-1.2 s warm. Hence the 2B is the recommended default and
    // the 0.8B is offered as the light-touch fallback for small machines.
    static let qwen0_8b = GGUFModelDescriptor(
        id: "qwen3.5-0.8b",
        displayName: "Qwen 3.5 0.8B — fastest, light-touch cleanup",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        sizeMB: 535,
        url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf",
        expectedSHA256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        expectedByteCount: 532_517_120,
        maxTokenCount: 4096,
        isRecommended: false
    )

    static let qwen2b = GGUFModelDescriptor(
        id: "qwen3.5-2b",
        displayName: "Qwen 3.5 2B — best cleanup",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        sizeMB: 1281,
        url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf",
        expectedSHA256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        expectedByteCount: 1_280_835_840,
        maxTokenCount: 4096,
        isRecommended: true
    )

    static let curated: [GGUFModelDescriptor] = [qwen2b, qwen0_8b]
    static let recommended = qwen2b

    static func descriptor(for id: String) -> GGUFModelDescriptor? {
        curated.first { $0.id == id }
    }

    static func fileURL(for descriptor: GGUFModelDescriptor, under modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent(descriptor.fileName)
    }

    /// Cheap presence check: file exists and is exactly the expected size.
    /// Safe to call per UI render; full-hash verification is `verify`.
    static func isDownloaded(_ descriptor: GGUFModelDescriptor, under modelsDir: URL) -> Bool {
        let file = fileURL(for: descriptor, under: modelsDir)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int64 else { return false }
        return size == descriptor.expectedByteCount
    }

    /// Full integrity check: byte count and streaming SHA-256. Run once after
    /// download and once before first load per app run — not per render.
    static func verify(_ descriptor: GGUFModelDescriptor, under modelsDir: URL) -> Bool {
        guard isDownloaded(descriptor, under: modelsDir) else { return false }
        let file = fileURL(for: descriptor, under: modelsDir)
        guard let digest = try? sha256Hex(of: file) else { return false }
        return digest == descriptor.expectedSHA256
    }

    /// Streaming SHA-256 (4 MB chunks) so a 1 GB model never sits in memory.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
