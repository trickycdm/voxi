import Foundation

/// The always-available, zero-dependency refiner. Every other backend falls
/// back to this one, so it must never fail.
struct RuleBasedRefiner: Refiner {
    let id = "rules"
    let displayName = "Rule-based (offline)"

    /// Supplies the personal dictionary (canonical terms + variants) at refine
    /// time, so edits in the Hub take effect without rebuilding the refiner.
    /// `RefinementContext.vocabulary` carries canonical terms only; the
    /// provider is how variant spellings reach the rules.
    private let dictionary: @Sendable () -> [DictionaryTerm]

    init(dictionary: @escaping @Sendable () -> [DictionaryTerm] = { [] }) {
        self.dictionary = dictionary
    }

    func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        RefinementRules.clean(transcript, dictionary: terms(merging: context))
    }

    func refineCard(from transcript: String, context: RefinementContext) async throws -> CardDraft {
        let cleaned = RefinementRules.clean(transcript, dictionary: terms(merging: context))
        return RefinementRules.draftCard(fromCleaned: cleaned)
    }

    func testConnection() async throws {
        // Always available — nothing to test.
    }

    private func terms(merging context: RefinementContext) -> [DictionaryTerm] {
        var all = dictionary()
        let known = Set(all.map { $0.canonical.lowercased() })
        all += context.vocabulary
            .filter { !known.contains($0.lowercased()) }
            .map { DictionaryTerm(canonical: $0) }
        return all
    }
}
