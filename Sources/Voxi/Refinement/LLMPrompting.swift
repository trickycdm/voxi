import Foundation

/// Shared prompt text for the two LLM backends, so OpenAI-compatible and
/// Anthropic refiners behave identically apart from transport.
enum LLMPrompts {

    static func dictationSystem(vocabulary: [String]) -> String {
        var prompt = """
        You clean up raw speech-to-text dictation. Rewrite the user's transcript by:
        - removing filler words (um, uh, erm, discourse "you know") and false starts
        - fixing punctuation and capitalization
        - applying self-corrections ("actually, scratch that", "no wait" — keep only the corrected version)
        - preserving the speaker's wording and meaning otherwise; do not summarize, expand, or answer questions in the transcript
        Return ONLY the cleaned text with no preamble, quotes, or commentary.
        """
        if !vocabulary.isEmpty {
            prompt += "\nSpell these personal-dictionary terms exactly as given: "
                + vocabulary.joined(separator: ", ") + "."
        }
        return prompt
    }

    static func cardSystem(vocabulary: [String]) -> String {
        var prompt = """
        The user dictated a task they want an autonomous agent to execute. Convert the raw transcript into a JSON object with exactly these keys:
        - "title": short imperative title, at most 48 characters
        - "summary": one-line summary of the task
        - "prompt": the dictation rewritten as a clear, self-contained instruction an agent could execute without extra context; remove fillers, apply self-corrections, keep every concrete detail (paths, names, technologies, constraints)
        Return ONLY the JSON object — no markdown fences, no commentary.
        """
        if !vocabulary.isEmpty {
            prompt += "\nSpell these personal-dictionary terms exactly as given: "
                + vocabulary.joined(separator: ", ") + "."
        }
        return prompt
    }
}

/// The JSON object LLM backends must return for `refineCard`.
struct CardPayload: Decodable, Sendable {
    let title: String
    let summary: String
    let prompt: String

    var draft: CardDraft {
        CardDraft(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            refinedByLLM: true
        )
    }
}

/// Lenient extraction of a JSON object from LLM output that may be wrapped in
/// code fences or prefixed with commentary.
enum LenientJSON {

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let json = extractObjectString(from: text),
              let data = json.data(using: .utf8) else {
            throw RefinerError.badResponse("no JSON object found in LLM output")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RefinerError.badResponse("JSON did not match the expected shape: \(error.localizedDescription)")
        }
    }

    static func extractObjectString(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = t.range(of: #"```[a-zA-Z]*"#, options: .regularExpression) {
            t = String(t[fence.upperBound...])
            if let close = t.range(of: "```") {
                t = String(t[..<close.lowerBound])
            }
        }
        guard let open = t.firstIndex(of: "{"),
              let close = t.lastIndex(of: "}"),
              open < close else { return nil }
        return String(t[open...close])
    }
}
