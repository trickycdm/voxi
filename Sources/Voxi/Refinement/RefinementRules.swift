import Foundation

/// A personal-dictionary term: the canonical spelling plus common
/// mishearings/misspellings that should be rewritten to it.
struct DictionaryTerm: Sendable, Equatable {
    var canonical: String
    var variants: [String]

    init(canonical: String, variants: [String] = []) {
        self.canonical = canonical
        self.variants = variants
    }

    init(_ entry: DictionaryEntry) {
        self.canonical = entry.term
        self.variants = entry.variants
    }
}

/// Pure transcript-cleanup logic behind `RuleBasedRefiner`, separated so every
/// rule is unit-testable without touching the Refiner protocol or async code.
enum RefinementRules {

    // MARK: - Pipeline

    static func clean(_ transcript: String, dictionary: [DictionaryTerm] = []) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = applyCorrections(text)
        text = removeFillers(text)
        text = enforceDictionary(text, terms: dictionary)
        text = cleanupPunctuation(text)
        text = capitalize(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    // MARK: - Self-corrections

    /// Standalone spoken-correction markers. An optional leading "actually"
    /// is swallowed so "Actually, scratch that" is treated as one marker.
    private static let markerPattern =
        #"(?:\bactually\b[,;]?\s+)?(?:\bscratch that\b|\bno,?\s+wait\b|\bwait,?\s+no\b)"#

    /// Semantics: a correction marker cancels the content of its own sentence
    /// that precedes it; the text after the marker (optionally introduced by
    /// "say") is the replacement. When the marker is a sentence of its own
    /// ("Actually, scratch that."), the *previous* sentence is what gets
    /// cancelled. Processing left-to-right makes "multiple corrections keep
    /// the last one" fall out naturally.
    static func applyCorrections(_ text: String) -> String {
        var s = text
        var safety = 0
        while safety < 64,
              let marker = s.range(of: markerPattern, options: [.regularExpression, .caseInsensitive]) {
            safety += 1
            let sentenceStart = startOfSentence(containing: marker.lowerBound, in: s)
            let preMarker = s[sentenceStart..<marker.lowerBound]
            let markerHasOwnContent = preMarker.contains { $0.isLetter || $0.isNumber }

            // The continuation starts after the marker, skipping separators
            // and an optional introducer ("scratch that, say X" keeps only X).
            var cursor = skip(charactersIn: ",;: \t\n", from: marker.upperBound, in: s)
            if let say = s.range(
                of: #"^say\b,?\s*"#,
                options: [.regularExpression, .caseInsensitive],
                range: cursor..<s.endIndex
            ) {
                cursor = say.upperBound
            }

            if cursor == s.endIndex || isSentenceTerminator(s[cursor]) {
                // No continuation inside the marker's sentence: drop the whole
                // marker sentence, plus the previous sentence when the marker
                // sentence had nothing of its own to cancel.
                let removalEnd = skip(charactersIn: ".!?… \t\n", from: cursor, in: s)
                let removalStart: String.Index
                if markerHasOwnContent {
                    removalStart = sentenceStart
                } else {
                    let previous = previousContentIndex(before: sentenceStart, in: s)
                    removalStart = startOfSentence(containing: previous, in: s)
                }
                s.removeSubrange(removalStart..<removalEnd)
            } else {
                s.removeSubrange(sentenceStart..<cursor)
            }
        }
        return s
    }

    // MARK: - Filler words

    static func removeFillers(_ text: String) -> String {
        var s = text
        // "um"/"uh"/"erm" are never real words; a word boundary (excluding
        // hyphenated compounds like "uh-huh") is enough. One neighboring comma
        // is absorbed so "Send, um, it" collapses cleanly.
        let strong = #"(?:,\s*)?(?<![\w-])(?:um|uh|erm)(?![\w-]),?"#
        s = s.replacingOccurrences(of: strong, with: "", options: [.regularExpression, .caseInsensitive])
        // "you know" is a real phrase — only drop it when it is set off by
        // pauses (punctuation or utterance edges) on BOTH sides.
        let weak = #"([,;:!?.]|^)\s*you know(?=\s*(?:[,;:!?.]|$))"#
        s = s.replacingOccurrences(of: weak, with: "$1", options: [.regularExpression, .caseInsensitive])
        return s
    }

    // MARK: - Personal dictionary

    /// Replaces variants and wrong-cased occurrences of each term with its
    /// canonical spelling, word-boundary-safe and case-insensitive.
    static func enforceDictionary(_ text: String, terms: [DictionaryTerm]) -> String {
        var s = text
        for term in terms {
            let canonical = term.canonical.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            let spellings = ([canonical] + term.variants)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count } // longest first so multi-word variants win
            let template = templateEscaped(canonical)
            for spelling in spellings {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: spelling) + "\\b"
                s = s.replacingOccurrences(
                    of: pattern,
                    with: template,
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }
        return s
    }

    // MARK: - Punctuation cleanup

    static func cleanupPunctuation(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[,;:\s]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Capitalization

    static func capitalize(_ text: String) -> String {
        var chars = Array(text)
        var expectCapital = true
        for i in chars.indices {
            let ch = chars[i]
            if expectCapital, ch.isLetter {
                let upper = String(ch).uppercased()
                if upper.count == 1, let u = upper.first { chars[i] = u }
                expectCapital = false
            } else if expectCapital, ch.isNumber {
                // "2 files remain." — the sentence starts with a digit;
                // don't capitalize the following word.
                expectCapital = false
            } else if isSentenceTerminator(ch) {
                // Only a terminator followed by whitespace (or end) ends a
                // sentence — "Next.js" must not capitalize "js".
                if i + 1 >= chars.count || chars[i + 1].isWhitespace {
                    expectCapital = true
                }
            }
        }
        // Standalone "i" and its contractions ("i'm", "i'll", ...).
        return String(chars).replacingOccurrences(
            of: #"(?<![\w])i(?=$|[\s'’,.!?;:])"#,
            with: "I",
            options: .regularExpression
        )
    }

    // MARK: - Terminal punctuation

    /// Multi-word dictations get a terminal period; single words ("hello",
    /// a password fragment, a search term) are left alone.
    static func ensureTerminalPunctuation(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let last = s.last else { return s }
        let words = s.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return s }
        if ".!?…\"'’”)".contains(last) { return s }
        if ",;:".contains(last) { return String(s.dropLast()) + "." }
        return s + "."
    }

    // MARK: - Card drafting

    /// Mechanical card draft used when no LLM backend is available:
    /// title = first clause (≤ 48 chars), summary = first sentence,
    /// prompt = the cleaned transcript verbatim.
    static func draftCard(fromCleaned cleaned: String) -> CardDraft {
        let firstSentence = self.firstSentence(of: cleaned)
        var title = firstClause(of: firstSentence)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?…"))
        if title.count > 48 {
            let head = String(title.prefix(47))
            if let cut = head.lastIndex(where: { $0.isWhitespace }),
               head.distance(from: head.startIndex, to: cut) >= 20 {
                title = String(head[..<cut])
            } else {
                title = head
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?…")) + "…"
        }
        return CardDraft(title: title, summary: firstSentence, prompt: cleaned, refinedByLLM: false)
    }

    static func firstSentence(of text: String) -> String {
        var i = text.startIndex
        while i < text.endIndex {
            if isSentenceTerminator(text[i]) {
                let next = text.index(after: i)
                // "Next.js" is not a sentence boundary.
                if next == text.endIndex || text[next].isWhitespace {
                    return String(text[...i])
                }
            }
            i = text.index(after: i)
        }
        return text
    }

    private static func firstClause(of sentence: String) -> String {
        guard let end = sentence.firstIndex(where: { ",;:—".contains($0) }) else { return sentence }
        return String(sentence[..<end])
    }

    // MARK: - Helpers

    private static func isSentenceTerminator(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "…"
    }

    private static func skip(charactersIn set: String, from index: String.Index, in s: String) -> String.Index {
        let chars = Set(set)
        var i = index
        while i < s.endIndex, chars.contains(s[i]) { i = s.index(after: i) }
        return i
    }

    /// Start of the sentence containing `index`: just past the previous
    /// sentence terminator, with intervening whitespace skipped.
    private static func startOfSentence(containing index: String.Index, in s: String) -> String.Index {
        var i = index
        while i > s.startIndex {
            let prev = s.index(before: i)
            // A terminator counts as a boundary only when followed by
            // whitespace ("Next.js" is not a sentence break).
            if isSentenceTerminator(s[prev]), i < s.endIndex, s[i].isWhitespace { break }
            i = prev
        }
        while i < index, s[i].isWhitespace { i = s.index(after: i) }
        return i
    }

    /// Index of the last content character strictly before `index`,
    /// skipping whitespace and sentence terminators.
    private static func previousContentIndex(before index: String.Index, in s: String) -> String.Index {
        var i = index
        while i > s.startIndex {
            let prev = s.index(before: i)
            if s[prev].isWhitespace || isSentenceTerminator(s[prev]) {
                i = prev
            } else {
                return prev
            }
        }
        return s.startIndex
    }

    /// Escapes a replacement string for use as an ICU regex template.
    private static func templateEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
