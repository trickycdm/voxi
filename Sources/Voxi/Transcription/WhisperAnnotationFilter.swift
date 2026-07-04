import Foundation

/// Strips Whisper's non-speech annotations ("[BLANK_AUDIO]", "(music)",
/// "[inaudible]" …) from transcripts. Whisper-family models emit these on
/// silence or noise; left in, they'd be inserted at the user's cursor as if
/// dictated. The live pipeline's SignalGuard catches outright silence before
/// transcription, but quiet-yet-not-silent captures can still reach the model.
enum WhisperAnnotationFilter {
    private static let pattern = #"[\[(]\s*(?i:blank[_ ]?audio|music|silence|silent|inaudible|applause|laughter|laughs|noise|no speech|speaking in foreign language|foreign language|cough(?:ing)?|breath(?:ing)?)\s*[\])]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return cleaned
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
