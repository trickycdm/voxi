import CryptoKit
import Foundation
import Testing
@testable import Voxi

@Suite struct LocalLLMCatalogTests {
    @Test func descriptorsAreWellFormed() {
        for descriptor in LocalLLMCatalog.curated {
            #expect(!descriptor.id.isEmpty)
            #expect(descriptor.fileName.hasSuffix(".gguf"))
            #expect(descriptor.expectedSHA256.count == 64)
            #expect(descriptor.expectedByteCount > 100_000_000)
            #expect(descriptor.maxTokenCount > 0)
        }
        #expect(LocalLLMCatalog.curated.filter(\.isRecommended).count == 1)
        #expect(LocalLLMCatalog.recommended.isRecommended)
    }

    @Test func urlsArePinnedToRevisions() {
        // …/resolve/<40-hex-commit>/<file> — never a branch name, so the
        // recorded hash can't be invalidated by upstream pushes.
        for descriptor in LocalLLMCatalog.curated {
            #expect(
                descriptor.url.range(
                    of: #"/resolve/[0-9a-f]{40}/"#, options: .regularExpression) != nil,
                "unpinned URL: \(descriptor.url)")
        }
    }

    @Test func descriptorLookup() {
        #expect(LocalLLMCatalog.descriptor(for: "qwen3.5-0.8b") == LocalLLMCatalog.qwen0_8b)
        #expect(LocalLLMCatalog.descriptor(for: "nope") == nil)
    }

    @Test func sha256MatchesKnownDigest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-llm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("fixture.bin")
        let data = Data("voxi".utf8)
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try LocalLLMCatalog.sha256Hex(of: file) == expected)
    }

    @Test func downloadStateChecksSizeAndHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-llm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("not a real model".utf8)
        let descriptor = GGUFModelDescriptor(
            id: "test", displayName: "Test", fileName: "test.gguf", sizeMB: 0,
            url: "https://example.com/resolve/0000000000000000000000000000000000000000/test.gguf",
            expectedSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            expectedByteCount: Int64(payload.count),
            maxTokenCount: 4096, isRecommended: false
        )

        // Absent.
        #expect(!LocalLLMCatalog.isDownloaded(descriptor, under: dir))
        #expect(!LocalLLMCatalog.verify(descriptor, under: dir))

        // Present with correct size + hash.
        try payload.write(to: LocalLLMCatalog.fileURL(for: descriptor, under: dir))
        #expect(LocalLLMCatalog.isDownloaded(descriptor, under: dir))
        #expect(LocalLLMCatalog.verify(descriptor, under: dir))

        // Same size, corrupted content: cheap check passes, full check fails.
        var corrupted = payload
        corrupted[0] = corrupted[0] &+ 1
        try corrupted.write(to: LocalLLMCatalog.fileURL(for: descriptor, under: dir))
        #expect(LocalLLMCatalog.isDownloaded(descriptor, under: dir))
        #expect(!LocalLLMCatalog.verify(descriptor, under: dir))

        // Truncated: cheap check fails.
        try payload.dropLast().write(to: LocalLLMCatalog.fileURL(for: descriptor, under: dir))
        #expect(!LocalLLMCatalog.isDownloaded(descriptor, under: dir))
    }
}

@Suite struct LocalLLMPromptTests {
    @Test func basePromptHasNoOCRReferences() {
        #expect(!LocalLLMPrompts.basePrompt.localizedCaseInsensitiveContains("ocr"))
        #expect(!LocalLLMPrompts.basePrompt.localizedCaseInsensitiveContains("window"))
    }

    @Test func emptyVocabularyYieldsBarePrompt() {
        #expect(LocalLLMPrompts.stablePrefix(vocabulary: []) == LocalLLMPrompts.basePrompt)
    }

    @Test func vocabularyRendersAsCorrectionHints() {
        let prefix = LocalLLMPrompts.stablePrefix(vocabulary: ["GRDB", "XcodeGen"])
        #expect(prefix.hasPrefix(LocalLLMPrompts.basePrompt))
        #expect(prefix.contains("<CORRECTION-HINTS>"))
        #expect(prefix.contains("- GRDB"))
        #expect(prefix.contains("- XcodeGen"))
        #expect(prefix.contains("</CORRECTION-HINTS>"))
    }

    @Test func stablePrefixIsDeterministic() {
        let vocab = ["Voxi", "Parakeet"]
        #expect(
            LocalLLMPrompts.stablePrefix(vocabulary: vocab)
                == LocalLLMPrompts.stablePrefix(vocabulary: vocab))
        #expect(
            LocalLLMPrompts.stablePrefix(vocabulary: vocab)
                != LocalLLMPrompts.stablePrefix(vocabulary: ["Voxi"]))
    }

    @Test func userInputIsWrapped() {
        let formatted = LocalLLMPrompts.formatUserInput("hello world")
        #expect(formatted.contains("<USER-INPUT>"))
        #expect(formatted.contains("hello world"))
        #expect(formatted.contains("</USER-INPUT>"))
    }
}

@Suite struct LocalRefinerTests {
    @Test func refineCardThrowsImmediately() async {
        let refiner = LocalRefiner(modelID: LocalLLMCatalog.recommended.id)
        await #expect(throws: RefinerError.self) {
            _ = try await refiner.refineCard(
                from: "do the thing", context: RefinementContext(mode: .command))
        }
    }

    @Test func chainFallsBackToRulesWhenLocalRefinerThrows() async {
        // The real LocalRefiner throws whenever its model isn't on disk —
        // exercising exactly the fallback invariant.
        let chain = RefinerChain(
            llm: LocalRefiner(modelID: "not-a-model"),
            rules: RuleBasedRefiner()
        )
        let outcome = await chain.refine(
            "um hello world", context: RefinementContext(mode: .dictation))
        #expect(outcome.refinerID == "rules")
        #expect(outcome.usedLLM == false)
        #expect(!outcome.text.isEmpty)

        let card = await chain.refineCard(
            from: "do the thing", context: RefinementContext(mode: .command))
        #expect(card.refinerID == "rules")
        #expect(card.draft.refinedByLLM == false)
    }

    @Test func factoryReturnsNilWhenModelAbsent() {
        var config = RefinerConfig()
        config.backend = .localLLM
        config.localModelID = "definitely-not-downloaded"
        #expect(config.makeLLMRefiner() == nil)
    }

    @Test func thinkBlocksAreStripped() {
        #expect(
            LocalLLMEngine.stripThinkBlocks("<think>reasoning</think>Hello there")
                == "Hello there")
        #expect(
            LocalLLMEngine.stripThinkBlocks("Hello <think>mid</think>world")
                == "Hello world")
        // Dangling opener truncates.
        #expect(LocalLLMEngine.stripThinkBlocks("<think>never closed") == "")
        #expect(LocalLLMEngine.stripThinkBlocks("plain output") == "plain output")
    }
}

@Suite struct RefinerConfigLocalLLMTests {
    @Test func legacyConfigJSONDecodesWithDefaults() throws {
        // Persisted by a build that predates localModelID.
        let legacy = Data("""
        {"backend":"anthropic","openAIBaseURL":"http://localhost:11434",
         "openAIModel":"","openAIAPIKey":"","anthropicAPIKey":"key",
         "anthropicModel":"claude-haiku-4-5-20251001"}
        """.utf8)
        let config = try JSONDecoder().decode(RefinerConfig.self, from: legacy)
        #expect(config.backend == .anthropic)
        #expect(config.anthropicAPIKey == "key")
        #expect(config.localModelID == LocalLLMCatalog.recommended.id)
    }

    @Test func localLLMBackendRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "voxi.tests.localLLMConfig"))
        defer { defaults.removePersistentDomain(forName: "voxi.tests.localLLMConfig") }

        var config = RefinerConfig()
        config.backend = .localLLM
        config.localModelID = LocalLLMCatalog.qwen2b.id
        config.save(to: defaults)

        let loaded = RefinerConfig.load(from: defaults)
        #expect(loaded == config)
    }
}

@Suite struct LocalLLMPrefillPlanTests {
    /// A fake ChatML rendering of `prefix + systemSentinel` as the system
    /// message and `userSentinel` as the user message.
    private func rendered(prefix: String) -> String {
        """
        <|im_start|>system
        \(prefix)\(LocalLLMPrefillPlan.systemSentinel)<|im_end|>
        <|im_start|>user
        \(LocalLLMPrefillPlan.userSentinel)<|im_end|>
        <|im_start|>assistant
        """
    }

    @Test func splitsRenderedPromptAroundSentinels() throws {
        let plan = try #require(LocalLLMPrefillPlan(
            systemPrefix: "SYSTEM", processedPrompt: rendered(prefix: "SYSTEM")))
        #expect(plan.contextPrefix == "<|im_start|>system\nSYSTEM")
        #expect(plan.promptSuffixAfterPrefix.contains("<|im_start|>user"))
        #expect(plan.suffixAfterUserInput.contains("assistant"))
        // Recombination must reproduce the full rendering exactly.
        let completion = try #require(plan.completionInput(for: "SYSTEM", userInput: "hello"))
        #expect(plan.contextPrefix + completion
            == rendered(prefix: "SYSTEM").replacingOccurrences(
                of: LocalLLMPrefillPlan.systemSentinel, with: "")
                .replacingOccurrences(of: LocalLLMPrefillPlan.userSentinel, with: "hello"))
    }

    @Test func dynamicSuffixAppendsAfterPrefix() throws {
        let plan = try #require(LocalLLMPrefillPlan(
            systemPrefix: "STABLE", processedPrompt: rendered(prefix: "STABLE")))
        let completion = try #require(
            plan.completionInput(for: "STABLE + dynamic tail", userInput: "hi"))
        #expect(completion.hasPrefix(" + dynamic tail"))
        #expect(completion.contains("hi"))
    }

    @Test func stalePrefixReturnsNil() throws {
        let plan = try #require(LocalLLMPrefillPlan(
            systemPrefix: "OLD VOCAB", processedPrompt: rendered(prefix: "OLD VOCAB")))
        #expect(plan.completionInput(for: "NEW VOCAB", userInput: "hi") == nil)
    }

    @Test func missingSentinelsFailInit() {
        #expect(LocalLLMPrefillPlan(systemPrefix: "S", processedPrompt: "no sentinels here") == nil)
    }
}

@Suite struct RefineEvalCLITests {
    @Test func parsesBareFlag() {
        #expect(CLIMode.parse(["--refine-eval"]) == .refineEval(inputPath: nil))
    }

    @Test func parsesFlagWithPath() {
        #expect(
            CLIMode.parse(["--refine-eval", "/tmp/cases.txt"])
                == .refineEval(inputPath: "/tmp/cases.txt"))
    }

    @Test func rejectsExtraArguments() {
        #expect(CLIMode.parse(["--refine-eval", "/tmp/cases.txt", "--engine"])
            == .invalid("--refine-eval takes only an optional transcript-file path"))
        #expect(CLIMode.parse(["--transcribe", "a.wav", "--refine-eval"])
            == .invalid("--refine-eval takes only an optional transcript-file path"))
    }

    @Test func chatbotVerdictHeuristics() {
        #expect(LocalLLMEvalCorpus.verdict(
            input: "What is 2 plus 2?",
            output: "As an AI language model, the answer is 4.").isChatbotResponse)
        #expect(LocalLLMEvalCorpus.verdict(
            input: "Can you help me write an email?",
            output: String(repeating: "Here is a detailed guide. ", count: 10)).isChatbotResponse)
        #expect(!LocalLLMEvalCorpus.verdict(
            input: "um so the meeting is at 3pm",
            output: "So the meeting is at 3pm.").isChatbotResponse)
    }
}
