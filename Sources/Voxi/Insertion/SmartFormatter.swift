import Foundation

/// Pure casing/spacing logic for dictated text landing at the caret.
///
/// The frozen `SmartFormatting` protocol carries a single character of
/// context; `format(_:before:unreadable:)` additionally accepts a short text
/// window before the caret so "terminator + space" still reads as a sentence
/// boundary. AXFocus supplies the window; the protocol method narrows to it.
struct SmartFormatter: SmartFormatting {

    func format(_ text: String, surroundings: InsertionSurroundings) -> String {
        format(
            text,
            before: surroundings.charBeforeCaret.map(String.init),
            unreadable: surroundings.unreadable
        )
    }

    /// - Parameter before: up to a few characters immediately preceding the
    ///   caret; nil or empty means start of field. Ignored when `unreadable`.
    func format(_ text: String, before: String?, unreadable: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if unreadable { return trimmed } // neutral: insert as transcribed

        let window = before ?? ""
        var result = trimmed

        switch Self.casing(for: window) {
        case .capitalize: result = Self.capitalizingFirstLetter(result)
        case .lowercase: result = Self.lowercasingFirstWordIfSafe(result)
        case .keep: break
        }

        if let immediate = window.last, Self.needsLeadingSpace(after: immediate) {
            result = " " + result
        }
        return result
    }

    // MARK: - Rules

    private enum Casing { case capitalize, lowercase, keep }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Characters after which inserted text needs a separating space.
    private static let closingPunctuation: Set<Character> =
        [".", "!", "?", "…", ",", ";", ":", ")", "]", "}", "\"", "'", "”", "’", "»", "%"]

    /// First words that are legitimately capitalized mid-sentence.
    private static let protectedWords: Set<String> =
        ["I", "I'm", "I'll", "I've", "I'd", "I’m", "I’ll", "I’ve", "I’d"]

    private static func casing(for window: String) -> Casing {
        // Anchor on the last non-space character so "terminator + optional
        // space" reads as a sentence start; newlines stay significant.
        guard let anchor = window.last(where: { $0 != " " && $0 != "\t" }) else {
            return .capitalize // start of field (or only spaces in view)
        }
        if anchor.isNewline || sentenceTerminators.contains(anchor) { return .capitalize }
        if anchor == "," || anchor.isLowercase { return .lowercase }
        return .keep // uppercase letter, digit, quote, etc. — too ambiguous
    }

    private static func needsLeadingSpace(after char: Character) -> Bool {
        char.isLetter || char.isNumber || closingPunctuation.contains(char)
    }

    private static func capitalizingFirstLetter(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Lowercase the first word only when it looks like ordinary sentence-case
    /// prose: first letter uppercase, rest lowercase, and not a protected form
    /// ("I", "I'm", …). Acronyms (NASA) and CamelCase (McDonald) are left alone.
    private static func lowercasingFirstWordIfSafe(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        let word = s.prefix { !$0.isWhitespace }
        let core = word.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        if protectedWords.contains(String(core)) { return s }
        guard core.dropFirst().allSatisfy({ !$0.isUppercase }) else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
