import Foundation
import LLM

/// Process-wide owner of the single loaded GGUF refiner model.
///
/// Deliberate singleton (documented exception to composition-root injection):
/// `RefinerChain` is rebuilt per dictation inside `DictationCoordinator`
/// via the `RefinerConfig.makeLLMRefiner` factory, which has no access to the
/// composition root — threading an instance through would change five seams
/// and break the "new refiner backend = one file + one registry entry"
/// invariant. llama.cpp's backend is process-global anyway, and loading the
/// same model twice would double ~0.6 GB of resident memory.
///
/// The `LLM` instance never escapes this actor — that is what satisfies
/// strict concurrency with a non-Sendable model type. Generation runs on the
/// actor; a timeout races it with a sleeping child task. On timeout the
/// in-flight llama loop may keep running to completion in the background
/// (llama doesn't observe cancellation mid-token); `isGenerating` makes the
/// next call fail fast to the rules refiner instead of queueing behind it.
actor LocalLLMEngine {
    static let shared = LocalLLMEngine()

    enum EngineError: Error, LocalizedError {
        case unknownModel(String)
        case modelNotDownloaded(String)
        case verificationFailed(String)
        case loadFailed(String)
        case busy
        case timedOut
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .unknownModel(let id): "Unknown on-device model '\(id)'"
            case .modelNotDownloaded(let id): "On-device model '\(id)' is not downloaded"
            case .verificationFailed(let id): "On-device model '\(id)' failed integrity verification"
            case .loadFailed(let id): "On-device model '\(id)' failed to load"
            case .busy: "On-device model is busy with another generation"
            case .timedOut: "On-device generation timed out"
            case .emptyOutput: "On-device model produced no output"
            }
        }
    }

    /// Every touch of the non-Sendable `LLM` happens inside this box's
    /// methods, so the raw instance never crosses an isolation boundary —
    /// only the box does. @unchecked is sound because the owning actor
    /// serializes all calls (`isGenerating` guards reentrancy) and the box
    /// never escapes the engine.
    private final class LLMBox: @unchecked Sendable {
        private let llm: LLM

        init?(path: String, maxTokenCount: Int32) {
            guard let llm = LLM(from: path, maxTokenCount: maxTokenCount) else { return nil }
            llm.temp = 0.1
            self.llm = llm
        }

        func generate(system: String, user: String) async -> String {
            llm.useResolvedTemplate(systemPrompt: system)
            llm.history = []
            await llm.respond(to: user, thinking: .suppressed)
            return llm.output
        }
    }

    private var box: LLMBox?
    private var loadedModelID: String?
    private var isGenerating = false
    /// Model IDs whose full SHA-256 was verified this app run — the expensive
    /// hash runs once per run, not per load.
    private var verifiedThisRun: Set<String> = []

    private let modelsDir: URL

    init(modelsDir: URL = VoxiPaths.modelsDir(engineID: LocalLLMCatalog.engineID)) {
        self.modelsDir = modelsDir
    }

    var isLoaded: Bool { box != nil }

    /// Idempotent: a no-op when the requested model is already resident.
    func ensureLoaded(modelID: String) throws {
        if loadedModelID == modelID, box != nil { return }
        guard let descriptor = LocalLLMCatalog.descriptor(for: modelID) else {
            throw EngineError.unknownModel(modelID)
        }
        guard LocalLLMCatalog.isDownloaded(descriptor, under: modelsDir) else {
            throw EngineError.modelNotDownloaded(modelID)
        }
        if !verifiedThisRun.contains(modelID) {
            guard LocalLLMCatalog.verify(descriptor, under: modelsDir) else {
                try? FileManager.default.removeItem(
                    at: LocalLLMCatalog.fileURL(for: descriptor, under: modelsDir))
                throw EngineError.verificationFailed(modelID)
            }
            verifiedThisRun.insert(modelID)
        }

        // Free the previous model before allocating the next one.
        box = nil
        loadedModelID = nil
        let path = LocalLLMCatalog.fileURL(for: descriptor, under: modelsDir).path
        guard let loaded = LLMBox(path: path, maxTokenCount: descriptor.maxTokenCount) else {
            throw EngineError.loadFailed(modelID)
        }
        box = loaded
        loadedModelID = modelID
    }

    func generate(
        system: String,
        user: String,
        timeout: TimeInterval = 15
    ) async throws -> String {
        guard !isGenerating else { throw EngineError.busy }
        guard let box else { throw EngineError.loadFailed(loadedModelID ?? "none") }
        isGenerating = true
        defer { isGenerating = false }

        let raw = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { await box.generate(system: system, user: user) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw EngineError.timedOut
            }
            guard let first = try await group.next() else { throw EngineError.emptyOutput }
            group.cancelAll()
            return first
        }

        let cleaned = Self.stripThinkBlocks(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw EngineError.emptyOutput }
        return cleaned
    }

    func unload() {
        box = nil
        loadedModelID = nil
    }

    // MARK: - Output sanitization

    /// Qwen-family models can emit reasoning inside <think> tags even when
    /// suppressed. Strip closed blocks, then truncate at a dangling opener.
    /// (Regexes lifted from ghost-pepper's TextCleaner, MIT.)
    private static let thinkBlock = try? NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*?</think>"#)
    private static let danglingThinkTag = try? NSRegularExpression(
        pattern: #"(?is)^\s*<think\b[^>]*>"#)

    static func stripThinkBlocks(_ text: String) -> String {
        var result = text
        if let thinkBlock {
            let range = NSRange(result.startIndex..., in: result)
            result = thinkBlock.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        if let danglingThinkTag {
            let range = NSRange(result.startIndex..., in: result)
            if let match = danglingThinkTag.firstMatch(in: result, range: range),
               let start = Range(match.range, in: result)?.lowerBound {
                result = String(result[..<start])
            }
        }
        return result
    }
}
