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

    /// The focused element is a password field. The machine-global secure
    /// input flag is judged separately by `SecureInput` — it must not be read
    /// as "focused field is secure" (MDM agents hold it session-long).
    static func isSecureField(_ target: FocusedTarget) -> Bool {
        target.subrole == kAXSecureTextFieldSubrole as String
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

    /// Full value read, capped at `fullValueReadLimit` UTF-16 units. Used by
    /// the post-insert correction observer; nil for huge documents — learning
    /// isn't worth a megabyte AX copy from a hung word processor. WebKit
    /// content that exposes no `kAXValue` falls back to text-marker ranges.
    static func fullText(of element: AXUIElement) -> String? {
        if let count = numberOfCharacters(of: element), count <= fullValueReadLimit,
           let value = copyString(element, kAXValueAttribute) {
            return value
        }
        return textMarkerText(of: element)
    }

    /// WebKit/browser text via AXTextMarker ranges — content areas there often
    /// return nothing for `kAXValue` (incantation from ghost-pepper, MIT).
    private static func textMarkerText(of element: AXUIElement) -> String? {
        func marker(_ attribute: String) -> AXTextMarker? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXTextMarkerGetTypeID() else { return nil }
            return unsafeBitCast(ref, to: AXTextMarker.self)
        }
        guard let start = marker("AXStartTextMarker"),
              let end = marker("AXEndTextMarker") else { return nil }
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &out) == .success,
              let text = out as? String, (text as NSString).length <= fullValueReadLimit
        else { return nil }
        return text
    }

    /// Duck-typing probe: does the app expose an *enabled* Paste item (⌘V,
    /// no other modifiers) in its menu bar? Apps that do support pasting even
    /// when the focused element advertises no AX text attributes — and apps
    /// that don't (no menu bar, Paste disabled) are not paste targets at all.
    /// Used only where tier selection is otherwise blind (no focused element).
    static func hasEnabledPasteMenuItem(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef, CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else {
            return false
        }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

        for menuBarItem in childElements(of: menuBar) {
            for submenu in childElements(of: menuBarItem) {
                for menuItem in childElements(of: submenu) where isPasteMenuItem(menuItem) {
                    var enabledRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        menuItem, kAXEnabledAttribute as CFString, &enabledRef) == .success,
                       let enabled = enabledRef as? Bool {
                        return enabled
                    }
                    return true
                }
            }
        }
        return false
    }

    private static func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        var charRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXMenuItemCmdChar" as CFString, &charRef) == .success,
              let cmdChar = charRef as? String, cmdChar.lowercased() == "v" else {
            return false
        }
        // AXMenuItemCmdModifiers: 0 = Command alone (no Shift/Option/Control).
        var modRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXMenuItemCmdModifiers" as CFString, &modRef) == .success,
           let modifiers = modRef as? Int, modifiers != 0 {
            return false
        }
        return true
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AnyObject] else { return [] }
        return children.compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            return ($0 as! AXUIElement)
        }
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
