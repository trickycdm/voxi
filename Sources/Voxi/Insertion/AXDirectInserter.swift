import ApplicationServices
import Foundation

/// Outcome of a tier-1 write. Chromium/Electron can return `.success` without
/// inserting, so success is only believed when the caret advanced by exactly
/// the written text's UTF-16 length.
enum AXWriteResult {
    case inserted
    /// Nothing landed — safe to fall through to the pasteboard tier.
    case caretDidNotMove
    /// The write may have partially landed; retrying risks double insertion.
    case indeterminate(String)
}

/// Tier 1: replace the (empty) selection via kAXSelectedTextAttribute.
@MainActor
enum AXDirectInserter {
    static func insert(_ text: String, into element: AXUIElement) -> AXWriteResult {
        // No pre-write caret means no way to verify afterwards — don't write.
        guard let before = AXFocus.selectedRange(of: element) else {
            return .caretDidNotMove
        }

        let err = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard err == .success else { return .caretDidNotMove }

        // AX ranges are UTF-16 units — NSString.length, never String.count.
        let expected = before.location + (text as NSString).length
        guard let after = AXFocus.selectedRange(of: element) else {
            return .indeterminate("write reported success but caret became unreadable")
        }
        if after.location == expected { return .inserted }
        if after.location == before.location && after.length == before.length {
            return .caretDidNotMove
        }
        return .indeterminate("caret at \(after.location), expected \(expected)")
    }
}
