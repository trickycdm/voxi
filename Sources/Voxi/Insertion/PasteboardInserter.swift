import AppKit
import Carbon.HIToolbox

/// One pasteboard item, every representation as raw Data.
typealias PasteboardItemSnapshot = [(type: NSPasteboard.PasteboardType, data: Data)]
typealias PasteboardSnapshot = [PasteboardItemSnapshot]

extension NSPasteboard.PasteboardType {
    /// Clipboard managers skip transient writes instead of archiving each transcription.
    static let voxiTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let voxiConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let voxiSource = NSPasteboard.PasteboardType("org.nspasteboard.source")
}

/// Tier 2 (default workhorse): clipboard write + synthesized Cmd+V, then a
/// guarded restore of whatever was on the clipboard before.
///
/// Timings follow what VoiceInk and espanso converged on: 100ms between the
/// pasteboard write and Cmd+V, 10ms between key events, and a >=300ms floor
/// before restoring (slow apps — Electron, RDP — read the pasteboard late).
@MainActor
enum PasteboardInserter {

    // MARK: - Snapshot / write / restore (unit-tested on a named pasteboard)

    static func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Writes the transcript with clipboard-manager markers. Returns the
    /// changeCount captured AFTER the write — the token guarding the restore.
    static func writeTranscript(
        _ text: String, to pasteboard: NSPasteboard, concealed: Bool
    ) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: .voxiTransient)
        if concealed { pasteboard.setData(Data(), forType: .voxiConcealed) }
        pasteboard.setString(Bundle.main.bundleIdentifier ?? "com.colin.voxi", forType: .voxiSource)
        return pasteboard.changeCount
    }

    /// Restores the snapshot only when nothing else touched the pasteboard
    /// since our write. NSPasteboardItems cannot be re-attached to a
    /// pasteboard — fresh items are rebuilt from the Data snapshot.
    @discardableResult
    static func restoreIfUnchanged(
        _ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard, expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        let items = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return true
    }

    // MARK: - Full tier-2/3 flow

    /// Runs the paste dance on the general pasteboard. `paste` posts Cmd+V by
    /// whatever mechanism the selected tier uses (CGEvent or AppleScript).
    static func insert(
        _ text: String,
        settings: InsertionSettings,
        paste: @MainActor () async throws -> Void
    ) async throws {
        let pasteboard = NSPasteboard.general
        // Snapshotting is a programmatic pasteboard READ (macOS 15.4+ alerts);
        // skip it entirely when restore is off.
        let snap = settings.restoreClipboard ? snapshot(of: pasteboard) : []
        let ourChangeCount = writeTranscript(text, to: pasteboard, concealed: settings.markConcealed)

        try await Task.sleep(for: .milliseconds(100))
        try await paste()
        try await Task.sleep(for: .milliseconds(max(300, settings.restoreDelayMilliseconds)))

        if settings.restoreClipboard {
            restoreIfUnchanged(snap, to: pasteboard, expectedChangeCount: ourChangeCount)
        }
    }

    /// Synthesizes Cmd+V. `.privateState` isolates the synthetic events from
    /// the user's physically-held hotkey modifiers; explicit `.maskCommand`
    /// flags stop those modifiers merging in.
    static func postCmdV() async throws {
        guard AXIsProcessTrusted() else {
            // CGEvent posts are silently dropped without the permission.
            throw InsertionError.allTiersFailed(
                "Accessibility permission not granted; cannot synthesize Cmd+V")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let cmdDown = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let vUp = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let cmdUp = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        else {
            throw InsertionError.allTiersFailed("could not create synthetic key events")
        }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        // cmdUp carries no flags — command is released.
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
