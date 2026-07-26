import Foundation
import Testing
@testable import Voxi

/// Real-model eval of the on-device refiner prompt. Requires the recommended
/// GGUF model to be downloaded (Hub → Refinement → On-device LLM) and is
/// env-gated because it loads ~0.6 GB and runs minutes of inference:
///
///     TEST_RUNNER_VOXI_LOCAL_LLM_EVAL=1 xcodebuild … test \
///       -only-testing:VoxiTests/LocalLLMEvalTests
@Suite(.serialized) struct LocalLLMEvalTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["VOXI_LOCAL_LLM_EVAL"] == "1"
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10)))
    func corpusPassesWithoutChatbotResponses() async throws {
        let modelID = LocalLLMCatalog.recommended.id
        let modelsDir = VoxiPaths.modelsDir(engineID: LocalLLMCatalog.engineID)
        try #require(
            LocalLLMCatalog.isDownloaded(LocalLLMCatalog.recommended, under: modelsDir),
            "download the recommended model in the Hub before running the eval")

        let refiner = LocalRefiner(modelID: modelID)
        for evalCase in LocalLLMEvalCorpus.cases {
            let start = Date()
            let output = try await refiner.refine(
                evalCase.input, context: RefinementContext(mode: .dictation))
            let elapsed = Date().timeIntervalSince(start)

            let verdict = LocalLLMEvalCorpus.verdict(input: evalCase.input, output: output)
            #expect(!verdict.isChatbotResponse,
                    "\(evalCase.input) → \(output) (\(verdict.reason); expected \(evalCase.expectation))")
            #expect(!output.isEmpty)
            #expect(elapsed <= LocalRefiner.generationTimeout + 1,
                    "case exceeded the generation timeout: \(evalCase.input)")
        }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(2)))
    func prefilledGenerationMatchesFullPath() async throws {
        let modelsDir = VoxiPaths.modelsDir(engineID: LocalLLMCatalog.engineID)
        try #require(
            LocalLLMCatalog.isDownloaded(LocalLLMCatalog.recommended, under: modelsDir))
        let modelID = LocalLLMCatalog.recommended.id
        let refiner = LocalRefiner(modelID: modelID)
        let input = "um so the meeting is at 3pm you know on Tuesday"

        // Full path first (also loads the model).
        let fullStart = Date()
        let fullOutput = try await refiner.refine(input, context: RefinementContext(mode: .dictation))
        let fullElapsed = Date().timeIntervalSince(fullStart)

        // Prefill the stable prefix (empty vocabulary = exactly what refine
        // renders for an empty dictionary), then refine again.
        await LocalLLMEngine.shared.prefill(
            systemPrefix: LocalLLMPrompts.stablePrefix(vocabulary: []), modelID: modelID)
        let prefilledStart = Date()
        let prefilledOutput = try await refiner.refine(input, context: RefinementContext(mode: .dictation))
        let prefilledElapsed = Date().timeIntervalSince(prefilledStart)

        #expect(!prefilledOutput.isEmpty)
        #expect(!LocalLLMEvalCorpus.verdict(input: input, output: prefilledOutput).isChatbotResponse)
        // Both paths should produce cleanup-shaped output of similar length.
        #expect(abs(prefilledOutput.count - fullOutput.count) < fullOutput.count)
        // The prefilled path must not be slower than the full path.
        #expect(prefilledElapsed <= fullElapsed + 1)

        // A stale prefill (different vocabulary) must degrade gracefully to
        // the full path, not fail.
        await LocalLLMEngine.shared.prefill(
            systemPrefix: LocalLLMPrompts.stablePrefix(vocabulary: ["StaleTerm"]), modelID: modelID)
        let afterStale = try await refiner.refine(input, context: RefinementContext(mode: .dictation))
        #expect(!afterStale.isEmpty)
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(2)))
    func fillersRemovedAndScratchThatHonored() async throws {
        let modelsDir = VoxiPaths.modelsDir(engineID: LocalLLMCatalog.engineID)
        try #require(
            LocalLLMCatalog.isDownloaded(LocalLLMCatalog.recommended, under: modelsDir))
        let refiner = LocalRefiner(modelID: LocalLLMCatalog.recommended.id)

        let fillers = try await refiner.refine(
            "um like so the meeting is at 3pm you know on Tuesday",
            context: RefinementContext(mode: .dictation))
        #expect(!fillers.lowercased().contains("um "))
        #expect(fillers.lowercased().contains("meeting"))

        // The safe failure mode is keeping the corrected-away text; the hard
        // requirement is that the intended recipient survives cleanup.
        let corrected = try await refiner.refine(
            "send it to Alice scratch that send it to Jordan",
            context: RefinementContext(mode: .dictation))
        #expect(corrected.lowercased().contains("jordan"))
    }
}
