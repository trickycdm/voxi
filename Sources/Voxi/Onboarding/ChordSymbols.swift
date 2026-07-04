import Foundation

/// Renders a ChordBinding as user-facing key symbols for the hotkey summary
/// ("fn", "fn + Space", "fn + ⌃"). Pure formatting, unit-tested.
enum ChordSymbols {
    /// One entry per key in the chord, macOS display order (fn ⌃ ⌥ ⇧ ⌘ key).
    static func parts(for binding: ChordBinding) -> [String] {
        var parts: [String] = []
        if binding.includesFn { parts.append("fn") }
        if binding.control { parts.append("⌃") }
        if binding.option { parts.append("⌥") }
        if binding.shift { parts.append("⇧") }
        if binding.command { parts.append("⌘") }
        if let keyCode = binding.keyCode { parts.append(keyName(keyCode)) }
        return parts
    }

    /// Single-string form, e.g. "fn + Space".
    static func label(for binding: ChordBinding) -> String {
        parts(for: binding).joined(separator: " + ")
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: "Space"
        case 36: "↩"
        case 48: "⇥"
        case 51: "⌫"
        case 53: "⎋"
        default: "key \(keyCode)"
        }
    }
}
