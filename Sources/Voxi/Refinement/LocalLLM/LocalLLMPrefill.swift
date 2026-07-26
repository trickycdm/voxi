import Foundation

/// Splits a chat-template-rendered prompt into the prefilled part and the
/// fragments recombined at generate time (pattern from ghost-pepper, MIT).
///
/// The template is rendered once with sentinel markers standing in for the
/// dynamic prompt tail and the user input. Everything before the system
/// sentinel — template header + stable system prefix — is `contextPrefix`,
/// which `prepareContext` evaluates into the KV cache while the user is
/// still speaking. At generate time `completionInput(for:userInput:)`
/// rebuilds exactly the remainder of the rendered prompt; a system prompt
/// that no longer starts with the prefilled prefix returns nil (stale
/// prefill → caller falls back to the full-evaluation path).
struct LocalLLMPrefillPlan: Equatable, Sendable {
    static let systemSentinel = "<|voxi-system-prefill-split|>"
    static let userSentinel = "<|voxi-user-prefill-split|>"

    let systemPrefix: String
    let contextPrefix: String
    let promptSuffixAfterPrefix: String
    let suffixAfterUserInput: String

    init?(systemPrefix: String, processedPrompt: String) {
        guard let systemSplit = processedPrompt.range(of: Self.systemSentinel) else { return nil }
        let afterSystem = String(processedPrompt[systemSplit.upperBound...])
        guard let userSplit = afterSystem.range(of: Self.userSentinel) else { return nil }

        self.systemPrefix = systemPrefix
        self.contextPrefix = String(processedPrompt[..<systemSplit.lowerBound])
        self.promptSuffixAfterPrefix = String(afterSystem[..<userSplit.lowerBound])
        self.suffixAfterUserInput = String(afterSystem[userSplit.upperBound...])
    }

    func completionInput(for systemPrompt: String, userInput: String) -> String? {
        guard systemPrompt.hasPrefix(systemPrefix) else { return nil }
        let dynamicSuffix = String(systemPrompt.dropFirst(systemPrefix.count))
        return dynamicSuffix + promptSuffixAfterPrefix + userInput + suffixAfterUserInput
    }
}
