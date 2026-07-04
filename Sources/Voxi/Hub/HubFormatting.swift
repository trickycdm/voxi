import Foundation

/// Renders a `ChordBinding` as user-facing key symbols, e.g. "⌃⌥", "fn Space",
/// "⇧⌘ K". Pure and unit-tested (HubFormattingTests).
enum ChordSymbols {
    /// Modifier glyphs in canonical macOS order (⌃⌥⇧⌘), then "fn", then the
    /// regular key's name. Groups are space-separated.
    static func render(_ binding: ChordBinding) -> String {
        var groups: [String] = []
        var glyphs = ""
        if binding.control { glyphs += "⌃" }
        if binding.option { glyphs += "⌥" }
        if binding.shift { glyphs += "⇧" }
        if binding.command { glyphs += "⌘" }
        if !glyphs.isEmpty { groups.append(glyphs) }
        if binding.includesFn { groups.append("fn") }
        if let keyCode = binding.keyCode { groups.append(keyName(keyCode)) }
        return groups.isEmpty ? "None" : groups.joined(separator: " ")
    }

    /// Human name for a CGKeyCode on the ANSI-US layout. Unknown codes fall
    /// back to "Key <code>" rather than guessing.
    static func keyName(_ keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
        117: "⌦", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Comma-separated variants field <-> `DictionaryEntry.variants` array.
enum VariantsCSV {
    /// Splits on commas, trims whitespace, drops empties, and dedupes
    /// case-insensitively while preserving order and casing of first sighting.
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func join(_ variants: [String]) -> String {
        variants.joined(separator: ", ")
    }
}

/// Term validation for the dictionary editor.
enum DictionaryValidation {
    /// The trimmed term, or nil when nothing usable was typed.
    static func normalizedTerm(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// "626 MB" / "1.5 GB" labels for model rows.
enum ModelSizeFormat {
    static func label(forMB sizeMB: Int?) -> String {
        guard let sizeMB else { return "size unknown" }
        if sizeMB >= 1024 {
            return String(format: "%.1f GB", Double(sizeMB) / 1024)
        }
        return "\(sizeMB) MB"
    }
}

/// Whether a History query should hit FTS search or show the recent list.
/// Mirrors `FTSQuery.sanitizedMatchPattern`'s notion of "searchable".
enum HistoryQueryMode: Equatable, Sendable {
    case recent
    case search(query: String)
}

enum HistoryQuery {
    static func mode(for raw: String) -> HistoryQueryMode {
        FTSQuery.sanitizedMatchPattern(raw) != nil ? .search(query: raw) : .recent
    }
}
