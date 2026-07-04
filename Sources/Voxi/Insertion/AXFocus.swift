import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What we know about the frontmost app and its focused UI element.
/// `element` is nil when the app exposes no focused element (common in
/// Electron apps) — the pasteboard tier still works then.
struct FocusedTarget {
    let appPID: pid_t
    let appBundleID: String?
    let appBundleURL: URL?
    let element: AXUIElement?
    let role: String?
    let subrole: String?
}

/// Surroundings for SmartFormatter plus the raw before-caret window that the
/// richer `format(_:before:unreadable:)` variant consumes.
struct SurroundingsReading {
    var surroundings: InsertionSurroundings
    /// Up to `AXFocus.windowLength` UTF-16 units immediately before the caret;
    /// nil at start of field or when unreadable.
    var textBeforeCaret: String?
}

/// Accessibility reads against the frontmost app's focused element.
/// All calls are short-fused (0.3s messaging timeout) so a hung target app
/// cannot stall the insertion path (default AX timeout is 6s).
@MainActor
enum AXFocus {
    static let messagingTimeout: Float = 0.3
    /// UTF-16 units read before the caret for casing decisions.
    static let windowLength = 3
    /// Skip the full-value fallback read on documents larger than this.
    private static let fullValueReadLimit = 100_000

    // MARK: - Focus

    static func frontmostTarget() -> FocusedTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        var element: AXUIElement?
        if err == .success, let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(el, messagingTimeout)
            element = el
        }
        return FocusedTarget(
            appPID: app.processIdentifier,
            appBundleID: app.bundleIdentifier,
            appBundleURL: app.bundleURL,
            element: element,
            role: element.flatMap { copyString($0, kAXRoleAttribute) },
            subrole: element.flatMap { copyString($0, kAXSubroleAttribute) }
        )
    }

    /// Refuse to dictate into password fields: AX subrole, or any process
    /// holding secure event input (covers fields AX cannot see).
    static func isSecure(_ target: FocusedTarget) -> Bool {
        if target.subrole == kAXSecureTextFieldSubrole as String { return true }
        return IsSecureEventInputEnabled()
    }

    // MARK: - Surroundings

    static func readSurroundings(of element: AXUIElement?) -> SurroundingsReading {
        guard let element, let sel = selectedRange(of: element), sel.location >= 0 else {
            return SurroundingsReading(
                surroundings: InsertionSurroundings(unreadable: true), textBeforeCaret: nil)
        }
        let caret = sel.location
        var before: String?
        var unreadable = false
        if caret > 0 {
            let length = min(windowLength, caret)
            before = string(for: CFRange(location: caret - length, length: length), in: element)
            // There is text before the caret but we can't see it — neutral formatting.
            if before == nil { unreadable = true }
        }
        let after = string(for: CFRange(location: sel.location + sel.length, length: 1), in: element)
        return SurroundingsReading(
            surroundings: InsertionSurroundings(
                charBeforeCaret: before?.last,
                charAfterCaret: after?.first,
                unreadable: unreadable),
            textBeforeCaret: before
        )
    }

    /// Caret/selection as UTF-16 units. Internal so tier 1 can verify writes.
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Probe before writing: tier-1 failure is not reliably reported after.
    static func canSetSelectedText(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    // MARK: - Electron

    /// Heuristic from the design doc: the app bundle ships Electron Framework.
    nonisolated static func isElectronApp(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Best-effort: ask Electron to build its AX tree (electron#37465 — some
    /// versions return .attributeUnsupported; never treat as a precondition).
    static func enableManualAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        _ = AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Attribute plumbing

    /// Windowed text read in UTF-16 units. Prefers the cheap parameterized
    /// attribute; falls back to slicing the full value on apps that lack it.
    private static func string(for range: CFRange, in element: AXUIElement) -> String? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var want = range
        if let axRange = AXValueCreate(.cfRange, &want) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out
            ) == .success, let s = out as? String {
                return s
            }
        }
        guard let count = numberOfCharacters(of: element), count <= fullValueReadLimit,
              let value = copyString(element, kAXValueAttribute)
        else { return nil }
        let ns = value as NSString
        guard range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func numberOfCharacters(of element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? Int
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }
}
