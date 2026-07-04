import AppKit

/// How the user wants text delivered.
enum InsertionMethod: String, Codable, Sendable, CaseIterable {
    /// Probe AX first; pasteboard when the focused element can't take the write.
    case auto
    /// Always clipboard + synthesized Cmd+V.
    case pasteboardAlways
    /// Clipboard + Cmd+V driven by System Events (needs Automation permission).
    case appleScript
}

struct InsertionSettings: Codable, Sendable, Equatable {
    var method: InsertionMethod = .auto
    /// Restore the previous clipboard after a pasteboard insert (changeCount-guarded).
    var restoreClipboard: Bool = true
    /// Mark writes org.nspasteboard.ConcealedType so managers treat them as sensitive.
    var markConcealed: Bool = false
    /// Delay before restoring the clipboard; floored at 300ms at use site.
    var restoreDelayMilliseconds: Int = 300

    static let defaultsKey = "insertionSettings"

    static func load(from defaults: UserDefaults = .standard) -> InsertionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(InsertionSettings.self, from: data)
        else { return InsertionSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Orchestrates one insertion: secure-field gate → read surroundings → smart
/// formatting → tier selection (probe BEFORE inserting — tier-2 failure is
/// not detectable after the fact).
@MainActor
final class TextInserter {
    var settings: InsertionSettings
    private let formatter = SmartFormatter()
    private let applePaster = AppleScriptPaster()

    init(settings: InsertionSettings = .load()) {
        self.settings = settings
    }

    func insert(_ text: String) async throws -> InsertionOutcome {
        guard let target = AXFocus.frontmostTarget() else {
            throw InsertionError.noFocusedElement
        }
        if AXFocus.isSecure(target) {
            throw InsertionError.secureField
        }

        let isElectron = AXFocus.isElectronApp(bundleURL: target.appBundleURL)
        if isElectron {
            // Best-effort nudge so surroundings reads have a chance of working.
            AXFocus.enableManualAccessibility(pid: target.appPID)
        }

        let reading = AXFocus.readSurroundings(of: target.element)
        let formatted = formatter.format(
            text,
            before: reading.textBeforeCaret,
            unreadable: reading.surroundings.unreadable)
        guard !formatted.isEmpty else {
            // Nothing left after trimming; touch nothing.
            return InsertionOutcome(tier: .accessibility, insertedText: "")
        }

        switch settings.method {
        case .appleScript:
            try await PasteboardInserter.insert(formatted, settings: settings) { [applePaster] in
                try applePaster.paste()
            }
            return InsertionOutcome(tier: .appleScript, insertedText: formatted)

        case .pasteboardAlways:
            try await pasteboardInsert(formatted)
            return InsertionOutcome(tier: .pasteboard, insertedText: formatted)

        case .auto:
            // Electron: AX writes return .success without inserting — skip tier 1.
            if let element = target.element, !isElectron, AXFocus.canSetSelectedText(element) {
                switch AXDirectInserter.insert(formatted, into: element) {
                case .inserted:
                    return InsertionOutcome(tier: .accessibility, insertedText: formatted)
                case .caretDidNotMove:
                    break // nothing landed; pasteboard tier is safe
                case .indeterminate(let why):
                    // May have partially landed — retrying would double-insert.
                    throw InsertionError.allTiersFailed("AX write indeterminate: \(why)")
                }
            }
            try await pasteboardInsert(formatted)
            return InsertionOutcome(tier: .pasteboard, insertedText: formatted)
        }
    }

    private func pasteboardInsert(_ text: String) async throws {
        try await PasteboardInserter.insert(text, settings: settings) {
            try await PasteboardInserter.postCmdV()
        }
    }
}
