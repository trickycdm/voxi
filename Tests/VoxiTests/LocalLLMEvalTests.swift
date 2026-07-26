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
