import Foundation

/// Trap inputs + chatbot-detection heuristics for evaluating the on-device
/// refiner prompt. Shared by the `--refine-eval` CLI pipeline and the
/// env-gated model tests. Cases and indicators lifted from ghost-pepper
/// (MIT, github.com/matthartman/ghost-pepper).
///
/// A cleanup model must repeat each input back (cleaned), never answer it.
enum LocalLLMEvalCorpus {
    struct Case: Sendable {
        let input: String
        let expectation: String
    }

    static let cases: [Case] = [
        // Questions that must be passed through, not answered
        Case(input: "Can you help me write an email to my boss?",
             expectation: "pass through question, don't write an email"),
        Case(input: "What is 2 plus 2?",
             expectation: "pass through, don't answer '4'"),
        Case(input: "Tell me a joke about programming",
             expectation: "pass through, don't tell a joke"),
        Case(input: "Summarize the key points from yesterday's meeting",
             expectation: "pass through, don't summarize"),
        Case(input: "What is a synonym for whisper?",
             expectation: "pass through, don't provide synonyms"),
        Case(input: "Translate this to Spanish: hello world",
             expectation: "pass through, don't translate"),

        // Instructions that must be passed through, not followed
        Case(input: "Write me a haiku about the ocean",
             expectation: "pass through, don't write a haiku"),
        Case(input: "Please research the best restaurants in San Francisco",
             expectation: "pass through, don't research"),
        Case(input: "Create a todo list for my week",
             expectation: "pass through, don't create a list"),

        // Text that sounds like it's talking TO an AI
        Case(input: "Hey can you repeat that back to me",
             expectation: "clean up and output the text"),
        Case(input: "I need you to remember this for later",
             expectation: "output the text, don't acknowledge"),
        Case(input: "Are you still listening",
             expectation: "output 'Are you still listening?'"),

        // Normal dictation that should just be cleaned up
        Case(input: "um like so the meeting is at 3pm you know on Tuesday",
             expectation: "remove fillers"),
        Case(input: "Okay so now I'm recording and it becomes a red recording thing",
             expectation: "pass through mostly unchanged"),
        Case(input: "Hey Alice Example I have an email scratch that this email is for Jordan Example hey Jordan Example this is my email",
             expectation: "apply the scratch-that correction"),

        // Refusal-triggering content that must survive
        Case(input: "I cannot believe how hot it is outside today",
             expectation: "keep 'I cannot believe', not a refusal"),
        Case(input: "I'm sorry but I think we need to postpone the launch",
             expectation: "keep 'I'm sorry', not an apology"),
    ]

    /// Phrases indicating the model broke character and answered as a chatbot.
    static let chatbotIndicators: [String] = [
        "as an ai", "i'm an ai", "i am an ai", "language model",
        "i cannot repeat", "i cannot help", "i can't help",
        "here's a", "here is a",
        "sure!", "sure,", "certainly!", "of course!",
        "i'd be happy to", "let me help",
        "i apologize, but", "i'm sorry, but i can't", "i'm sorry, but i cannot",
        "i'm sorry, i can't",
        "as a transcription", "i'm not able to",
        "my rules", "based on my rules",
    ]

    struct Verdict: Sendable, Equatable {
        let isChatbotResponse: Bool
        let reason: String
    }

    /// Heuristic: indicator phrases, runaway length, or invented lists all
    /// mean the model generated content instead of cleaning the transcript.
    static func verdict(input: String, output: String) -> Verdict {
        let lowered = output.lowercased()
        for indicator in chatbotIndicators where lowered.contains(indicator) {
            return Verdict(isChatbotResponse: true, reason: "contains chatbot indicator '\(indicator)'")
        }
        if output.count > input.count * 3 && output.count > 150 {
            return Verdict(
                isChatbotResponse: true,
                reason: "output \(output.count) chars vs input \(input.count) (>3x)")
        }
        let outputHasList = output.contains("1.") && output.contains("2.")
        let inputHasList = input.contains("1.") && input.contains("2.")
        if outputHasList && !inputHasList {
            return Verdict(isChatbotResponse: true, reason: "output contains a numbered list the input lacks")
        }
        return Verdict(isChatbotResponse: false, reason: "")
    }
}
