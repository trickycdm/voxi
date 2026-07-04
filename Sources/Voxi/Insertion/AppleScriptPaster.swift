import AppKit

/// Tier 3: drive Cmd+V through System Events. Uses `key code 9` (the physical
/// V key), not `keystroke "v"`, so "X – QWERTY ⌘" input sources don't remap
/// it. Only used when the user explicitly selects the AppleScript method —
/// never auto-chained after tier 2 (double-insert risk, extra Automation
/// permission prompt).
///
/// NSAppleScript is main-thread-only; the script is compiled once and cached.
@MainActor
final class AppleScriptPaster {
    private var script: NSAppleScript?

    func paste() throws {
        if script == nil {
            guard let compiled = NSAppleScript(
                source: "tell application \"System Events\" to key code 9 using command down")
            else {
                throw InsertionError.allTiersFailed("could not create AppleScript")
            }
            var compileError: NSDictionary?
            guard compiled.compileAndReturnError(&compileError) else {
                throw InsertionError.allTiersFailed(
                    "AppleScript compile failed: \(compileError ?? [:])")
            }
            script = compiled
        }

        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                throw InsertionError.allTiersFailed(
                    "Automation permission denied for System Events "
                    + "(System Settings > Privacy & Security > Automation)")
            }
            throw InsertionError.allTiersFailed("AppleScript paste failed: \(error)")
        }
    }
}
