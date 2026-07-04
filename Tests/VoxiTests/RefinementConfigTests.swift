import Foundation
import Testing
@testable import Voxi

/// Pure stub backend for exercising `RefinerChain` without HTTP.
private struct StubRefiner: Refiner {
    let id = "stub-llm"
    let displayName = "Stub"
    var result: Result<String, RefinerError> = .success("LLM cleaned text.")
    var cardResult: Result<CardDraft, RefinerError> =
        .success(CardDraft(title: "T", summary: "S", prompt: "P", refinedByLLM: false))

    func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        try result.get()
    }

    func refineCard(from transcript: String, context: RefinementContext) async throws -> CardDraft {
        try cardResult.get()
    }

    func testConnection() async throws {}
}

@Suite struct RefinerConfigTests {
    @Test func defaultsToRulesBackend() {
        let config = RefinerConfig()
        #expect(config.backend == .rules)
        #expect(config.makeLLMRefiner() == nil)
    }

    @Test func saveLoadRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "voxi.tests.refinerConfig"))
        defer { defaults.removePersistentDomain(forName: "voxi.tests.refinerConfig") }

        var config = RefinerConfig()
        config.backend = .openAICompat
        config.openAIBaseURL = "http://localhost:8080/v1"
        config.openAIModel = "qwen3"
        config.anthropicAPIKey = "sk-ant-x"
        config.save(to: defaults)

        #expect(RefinerConfig.load(from: defaults) == config)
    }

    @Test func loadWithNoStoredDataReturnsDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "voxi.tests.refinerConfig.empty"))
        defer { defaults.removePersistentDomain(forName: "voxi.tests.refinerConfig.empty") }
        #expect(RefinerConfig.load(from: defaults) == RefinerConfig())
    }

    @Test func openAIBackendRequiresModelAndValidURL() {
        var config = RefinerConfig()
        config.backend = .openAICompat
        config.openAIModel = ""
        config.openAIBaseURL = "http://localhost:11434"
        #expect(config.makeLLMRefiner() == nil)

        config.openAIModel = "llama3.2"
        config.openAIBaseURL = "not a url"
        #expect(config.makeLLMRefiner() == nil)

        config.openAIBaseURL = " http://localhost:11434 "
        let refiner = config.makeLLMRefiner() as? OpenAICompatRefiner
        #expect(refiner?.id == "openai-compat")
        #expect(refiner?.model == "llama3.2")
        #expect(refiner?.apiKey == nil)
        #expect(refiner?.baseURL.absoluteString == "http://localhost:11434")
    }

    @Test func anthropicBackendRequiresKeyAndDefaultsModel() {
        var config = RefinerConfig()
        config.backend = .anthropic
        #expect(config.makeLLMRefiner() == nil)

        config.anthropicAPIKey = "sk-ant-x"
        config.anthropicModel = "   "
        let refiner = config.makeLLMRefiner() as? AnthropicRefiner
        #expect(refiner?.id == "anthropic")
        #expect(refiner?.apiKey == "sk-ant-x")
        #expect(refiner?.model == AnthropicRefiner.defaultModel)
    }

    @Test func backendIDsMatchRefinerIDs() {
        #expect(RefinerBackendID.rules.rawValue == RuleBasedRefiner().id)
        #expect(RefinerBackendID.openAICompat.rawValue == "openai-compat")
        #expect(RefinerBackendID.anthropic.rawValue == "anthropic")
    }
}

@Suite struct RefinerChainTests {
    @Test func usesLLMWhenItSucceeds() async {
        let chain = RefinerChain(llm: StubRefiner(), rules: RuleBasedRefiner())
        #expect(chain.activeRefinerID == "stub-llm")
        let outcome = await chain.refine("um whatever", context: RefinementContext())
        #expect(outcome == RefinementOutcome(text: "LLM cleaned text.", refinerID: "stub-llm", usedLLM: true))
    }

    @Test func fallsBackToRulesWhenLLMThrows() async {
        var stub = StubRefiner()
        stub.result = .failure(.badResponse("boom"))
        let chain = RefinerChain(llm: stub, rules: RuleBasedRefiner())
        let outcome = await chain.refine("um send the report", context: RefinementContext())
        #expect(outcome == RefinementOutcome(text: "Send the report.", refinerID: "rules", usedLLM: false))
    }

    @Test func noLLMConfiguredRunsRulesDirectly() async {
        let chain = RefinerChain(llm: nil, rules: RuleBasedRefiner())
        #expect(chain.activeRefinerID == "rules")
        let outcome = await chain.refine("uh hello there", context: RefinementContext())
        #expect(outcome == RefinementOutcome(text: "Hello there.", refinerID: "rules", usedLLM: false))
    }

    @Test func cardOutcomeForcesRefinedByLLMTrueOnLLMSuccess() async {
        // Even if a backend forgets to set the flag, the chain knows an LLM ran.
        let chain = RefinerChain(llm: StubRefiner(), rules: RuleBasedRefiner())
        let outcome = await chain.refineCard(from: "build it", context: RefinementContext(mode: .command))
        #expect(outcome.refinerID == "stub-llm")
        #expect(outcome.draft.refinedByLLM == true)
    }

    @Test func cardFallbackDraftsMechanically() async {
        var stub = StubRefiner()
        stub.cardResult = .failure(.backendUnavailable("offline"))
        let chain = RefinerChain(llm: stub, rules: RuleBasedRefiner())
        let outcome = await chain.refineCard(
            from: "um, create a tracker app. Put it in repos.",
            context: RefinementContext(mode: .command)
        )
        #expect(outcome.refinerID == "rules")
        #expect(outcome.draft.refinedByLLM == false)
        #expect(outcome.draft.title == "Create a tracker app")
        #expect(outcome.draft.prompt == "Create a tracker app. Put it in repos.")
    }

    @Test func configBuiltChainWithRulesBackendHasNoLLM() {
        let chain = RefinerChain(config: RefinerConfig())
        #expect(chain.activeRefinerID == "rules")
    }
}
