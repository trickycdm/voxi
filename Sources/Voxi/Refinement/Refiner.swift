import Foundation

/// What a refinement pass is for.
enum RefinementMode: Sendable {
    /// Clean up dictation before inserting at the cursor.
    case dictation
    /// Rewrite a command-mode transcript into an action card.
    case command
}

struct RefinementContext: Sendable {
    var mode: RefinementMode = .dictation
    /// Personal-dictionary terms whose spellings must be respected.
    var vocabulary: [String] = []
}

/// Structured result of refining a command-mode transcript into an action card.
struct CardDraft: Sendable, Equatable {
    var title: String
    var summary: String
    /// The dictation rewritten as a clear, self-contained instruction an agent could execute.
    var prompt: String
    /// False when no LLM backend was available and the cleaned transcript was used verbatim.
    var refinedByLLM: Bool
}

enum RefinerError: Error, LocalizedError {
    case backendUnavailable(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .backendUnavailable(let why): "Refiner backend unavailable: \(why)"
        case .badResponse(let why): "Refiner returned an unusable response: \(why)"
        }
    }
}

/// A pluggable transcript post-processor. Three backends ship in v1:
/// rule-based (always available), OpenAI-compatible local endpoint, Anthropic API.
protocol Refiner: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Clean a raw transcript (filler words, punctuation, self-corrections).
    func refine(_ transcript: String, context: RefinementContext) async throws -> String

    /// Turn a command-mode transcript into a card draft. LLM backends produce
    /// title/summary/prompt; the rule-based backend derives them mechanically
    /// and sets `refinedByLLM = false`.
    func refineCard(from transcript: String, context: RefinementContext) async throws -> CardDraft

    /// Cheap connectivity check for the Settings "Test connection" button.
    func testConnection() async throws
}
