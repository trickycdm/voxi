import Foundation

/// How the text ended up in the target app.
enum InsertionTier: String, Sendable {
    case accessibility  // AX kAXSelectedTextAttribute write
    case pasteboard     // clipboard + synthesized Cmd+V
    case appleScript    // System Events key code 9 (user-opt-in tier)
}

struct InsertionOutcome: Sendable {
    var tier: InsertionTier
    /// Text as actually inserted, after smart casing/spacing adjustment.
    var insertedText: String
}

enum InsertionError: Error, LocalizedError {
    case secureField
    /// The target app (or an unidentifiable process) holds secure event input.
    case secureInputHeld(by: String?)
    case noFocusedElement
    case allTiersFailed(String)

    var errorDescription: String? {
        switch self {
        case .secureField: "Refusing to insert into a secure (password) field"
        case .secureInputHeld(let holder):
            if let holder {
                "\(holder) is capturing secure input — not inserting"
            } else {
                "Secure input is on (holder unknown) — not inserting"
            }
        case .noFocusedElement: "No focused text field found"
        case .allTiersFailed(let why): "Text insertion failed: \(why)"
        }
    }
}

/// Context read from the focused field, used to decide casing/spacing.
/// Kept as a plain value so SmartFormatter is unit-testable without AX.
struct InsertionSurroundings: Sendable, Equatable {
    /// Character immediately before the caret; nil = start of field or unreadable.
    var charBeforeCaret: Character?
    /// Character immediately after the caret; nil = end of field or unreadable.
    var charAfterCaret: Character?
    /// True when the AX read failed entirely (Electron etc.) — use neutral formatting.
    var unreadable: Bool = false
}

/// Pure decision logic for smart insertion; implemented + unit-tested in Insertion module.
protocol SmartFormatting: Sendable {
    /// Adjust `text` for its destination: leading/trailing space, first-word casing.
    func format(_ text: String, surroundings: InsertionSurroundings) -> String
}
