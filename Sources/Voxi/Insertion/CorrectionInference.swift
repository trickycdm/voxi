import Foundation

/// Infers a narrow `wrong → right` correction from the user's manual edits
/// after an insertion. Pure logic (heuristic ported from ghost-pepper, MIT);
/// the polling shell is `PostInsertObserver`.
///
/// The diff is word-level: shared prefix + shared suffix, changed middle
/// spans become the candidate pair. Guards keep it to high-confidence
/// name/term fixes — a wholesale rewrite never produces a correction:
/// - both sides non-empty, ≤ 2 words each
/// - not a punctuation/case-only difference
/// - `wrong` must appear as a word sequence in the originally inserted text
enum CorrectionInference {
    struct Correction: Equatable, Sendable {
        let wrong: String
        let right: String
    }

    static let maximumReplacementWordCount = 2

    static func inferredCorrection(
        from baseline: String,
        to observed: String,
        constrainedTo insertedText: String
    ) -> Correction? {
        let trimmedBaseline = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedObserved = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseline.isEmpty,
              !trimmedObserved.isEmpty,
              trimmedBaseline.caseInsensitiveCompare(trimmedObserved) != .orderedSame else {
            return nil
        }

        let baselineWords = words(in: trimmedBaseline)
        let observedWords = words(in: trimmedObserved)
        let prefixCount = sharedPrefixLength(between: baselineWords, and: observedWords)
        let suffixCount = sharedSuffixLength(
            between: baselineWords, and: observedWords, excludingPrefix: prefixCount)
        guard prefixCount > 0 || suffixCount > 0 else { return nil }

        let wrongSpan = baselineWords[prefixCount..<(baselineWords.count - suffixCount)]
            .joined(separator: " ")
        let rightSpan = observedWords[prefixCount..<(observedWords.count - suffixCount)]
            .joined(separator: " ")

        // Voxi stores the pair as dictionary term + variant, matched later by
        // word-boundary regex — surrounding punctuation would neuter it.
        let wrong = trimSurroundingPunctuation(wrongSpan)
        let right = trimSurroundingPunctuation(rightSpan)

        guard !wrong.isEmpty,
              !right.isEmpty,
              wrong.caseInsensitiveCompare(right) != .orderedSame,
              !differOnlyByPunctuation(wrong, right),
              wordCount(in: wrong) <= maximumReplacementWordCount,
              wordCount(in: right) <= maximumReplacementWordCount,
              containsWordSequence(wrong, in: insertedText) else {
            return nil
        }

        return Correction(wrong: wrong, right: right)
    }

    // MARK: - Word helpers

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func wordCount(in text: String) -> Int {
        words(in: text).count
    }

    private static func sharedPrefixLength(between lhs: [String], and rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit && lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private static func sharedSuffixLength(
        between lhs: [String], and rhs: [String], excludingPrefix prefixLength: Int
    ) -> Int {
        let limit = min(lhs.count, rhs.count) - prefixLength
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit && lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1] {
            count += 1
        }
        return count
    }

    private static func trimSurroundingPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private static func differOnlyByPunctuation(_ lhs: String, _ rhs: String) -> Bool {
        normalizedComparisonText(lhs) == normalizedComparisonText(rhs)
    }

    /// Alphanumerics only, single-spaced, lowercased — for "did anything
    /// meaningful change" comparisons.
    static func normalizedComparisonText(_ text: String) -> String {
        let mapped = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func containsWordSequence(_ needle: String, in haystack: String) -> Bool {
        let needleWords = words(in: needle)
        let haystackWords = words(in: haystack)
            .map { trimSurroundingPunctuation($0) }
            .filter { !$0.isEmpty }
        guard !needleWords.isEmpty, needleWords.count <= haystackWords.count else { return false }

        for start in 0...(haystackWords.count - needleWords.count) {
            let candidate = haystackWords[start..<(start + needleWords.count)]
            if zip(candidate, needleWords).allSatisfy({
                $0.caseInsensitiveCompare($1) == .orderedSame
            }) {
                return true
            }
        }
        return false
    }
}
