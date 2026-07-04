import Foundation

/// Which refiner backend the user selected in Settings.
enum RefinerBackendID: String, Codable, CaseIterable, Sendable {
    case rules
    case openAICompat = "openai-compat"
    case anthropic

    var displayName: String {
        switch self {
        case .rules: "Rule-based (offline)"
        case .openAICompat: "Local LLM (OpenAI-compatible)"
        case .anthropic: "Anthropic API"
        }
    }
}

/// Persisted refinement settings. Stored as JSON in UserDefaults.
///
/// NOTE: API keys living in UserDefaults is an accepted v1 tradeoff for a
/// local, single-user tool; migrating them to the Keychain is a known
/// follow-up.
struct RefinerConfig: Codable, Equatable, Sendable {
    var backend: RefinerBackendID = .rules

    var openAIBaseURL: String = "http://localhost:11434"
    var openAIModel: String = ""
    var openAIAPIKey: String = ""

    var anthropicAPIKey: String = ""
    var anthropicModel: String = AnthropicRefiner.defaultModel

    static let defaultsKey = "voxi.refinerConfig"

    static func load(from defaults: UserDefaults = .standard) -> RefinerConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(RefinerConfig.self, from: data) else {
            return RefinerConfig()
        }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The configured LLM refiner, or nil when the selected backend is rules
    /// or its required fields are missing/invalid (→ rules-only operation).
    func makeLLMRefiner(session: URLSession = .shared) -> (any Refiner)? {
        switch backend {
        case .rules:
            return nil
        case .openAICompat:
            let urlString = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty,
                  let url = URL(string: urlString),
                  url.scheme != nil, url.host != nil else {
                return nil
            }
            let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenAICompatRefiner(
                baseURL: url,
                model: model,
                apiKey: key.isEmpty ? nil : key,
                session: session
            )
        case .anthropic:
            let key = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let model = anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return AnthropicRefiner(
                apiKey: key,
                model: model.isEmpty ? AnthropicRefiner.defaultModel : model,
                session: session
            )
        }
    }
}

/// Result of a chained refinement: the cleaned text plus which backend
/// actually produced it (for history's `refinerID`).
struct RefinementOutcome: Sendable, Equatable {
    var text: String
    var refinerID: String
    var usedLLM: Bool
}

/// Result of a chained card refinement. `draft.refinedByLLM` matches whether
/// the LLM backend actually ran.
struct CardOutcome: Sendable, Equatable {
    var draft: CardDraft
    var refinerID: String
}

/// Runs the configured LLM refiner when there is one, with automatic
/// fallback to the rule-based refiner on ANY error — so refinement can never
/// break the dictation loop.
struct RefinerChain: Sendable {
    let llm: (any Refiner)?
    let rules: RuleBasedRefiner

    init(
        config: RefinerConfig,
        dictionary: @escaping @Sendable () -> [DictionaryTerm] = { [] },
        session: URLSession = .shared
    ) {
        self.llm = config.makeLLMRefiner(session: session)
        self.rules = RuleBasedRefiner(dictionary: dictionary)
    }

    /// Direct injection, primarily for tests.
    init(llm: (any Refiner)?, rules: RuleBasedRefiner) {
        self.llm = llm
        self.rules = rules
    }

    /// The backend that will be tried first.
    var activeRefinerID: String { llm?.id ?? rules.id }

    func refine(_ transcript: String, context: RefinementContext) async -> RefinementOutcome {
        if let llm {
            do {
                let text = try await llm.refine(transcript, context: context)
                return RefinementOutcome(text: text, refinerID: llm.id, usedLLM: true)
            } catch {
                voxiLog.warning("Refiner \(llm.id) failed, falling back to rules: \(error.localizedDescription)")
            }
        }
        let text = (try? await rules.refine(transcript, context: context)) ?? transcript
        return RefinementOutcome(text: text, refinerID: rules.id, usedLLM: false)
    }

    func refineCard(from transcript: String, context: RefinementContext) async -> CardOutcome {
        if let llm {
            do {
                var draft = try await llm.refineCard(from: transcript, context: context)
                draft.refinedByLLM = true
                return CardOutcome(draft: draft, refinerID: llm.id)
            } catch {
                voxiLog.warning("Card refiner \(llm.id) failed, falling back to rules: \(error.localizedDescription)")
            }
        }
        let cleaned = (try? await rules.refine(transcript, context: context)) ?? transcript
        return CardOutcome(draft: RefinementRules.draftCard(fromCleaned: cleaned), refinerID: rules.id)
    }
}
