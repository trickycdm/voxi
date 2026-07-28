import AppKit

enum TerminalLaunchError: Error, LocalizedError {
    /// AppleScript error -1743: the user has not granted (or has revoked)
    /// Automation permission for the target terminal app.
    case automationDenied(appName: String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied(let appName):
            "Automation permission denied for \(appName) "
                + "(System Settings > Privacy & Security > Automation)"
        case .scriptFailed(let why):
            "Could not open terminal window: \(why)"
        }
    }
}

/// Opens a new terminal window running a shell command line, via AppleScript.
/// Prefers iTerm2; falls back to Terminal.app when iTerm is not installed.
///
/// The terminal's shell parsing the command is the point here — the steering
/// "never spawn through a shell" rule is about `Process`. Everything variable
/// in the command goes through `shellQuoted`, and the whole command through
/// `escapedForAppleScript`.
enum TerminalLauncher {
    enum TerminalApp: String, Sendable {
        // Bundle ids, not app names — iTerm has shipped as both "iTerm" and
        // "iTerm2", and `tell application id` is rename-proof.
        case iTerm = "com.googlecode.iterm2"
        case terminal = "com.apple.Terminal"

        var displayName: String {
            switch self {
            case .iTerm: "iTerm"
            case .terminal: "Terminal"
            }
        }
    }

    @MainActor
    static func installedApp() -> TerminalApp {
        let iTermURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: TerminalApp.iTerm.rawValue)
        return iTermURL != nil ? .iTerm : .terminal
    }

    /// Picks the installed terminal, builds the script, and runs it.
    /// Returns the app used so callers can report "Opened in iTerm".
    ///
    /// `installedApp()` must run before script creation: instantiating an
    /// AppleScript that `tell`s a missing application fails at compile.
    @MainActor
    @discardableResult
    static func launch(command: String) throws -> TerminalApp {
        let app = installedApp()
        guard let script = NSAppleScript(source: script(for: app, command: command)) else {
            throw TerminalLaunchError.scriptFailed("could not create AppleScript")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                throw TerminalLaunchError.automationDenied(appName: app.displayName)
            }
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw TerminalLaunchError.scriptFailed(message)
        }
        return app
    }

    // MARK: - Pure text building (unit-tested)

    static func script(for app: TerminalApp, command: String) -> String {
        let escaped = escapedForAppleScript(command)
        switch app {
        case .iTerm:
            return """
            tell application id "\(app.rawValue)"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        case .terminal:
            // `do script` with no window target opens a new window.
            return """
            tell application id "\(app.rawValue)"
                activate
                do script "\(escaped)"
            end tell
            """
        }
    }

    /// `cd '<dir>' && '<claude>' [--resume '<sid>'] "$(cat '<file>')"; rm -f '<file>'`
    ///
    /// The prompt travels by temp file, never on the command line; command
    /// substitution inside double quotes is not re-expanded, so quotes, `$`,
    /// and backticks in the prompt arrive verbatim. `; rm` (not `&&`) so the
    /// file is cleaned up even when claude exits nonzero.
    static func launchCommand(
        claudePath: String,
        workingDirectory: String,
        promptFilePath: String,
        resumeSessionID: String? = nil
    ) -> String {
        var invocation = shellQuoted(claudePath)
        if let resumeSessionID {
            invocation += " --resume \(shellQuoted(resumeSessionID))"
        }
        let file = shellQuoted(promptFilePath)
        return "cd \(shellQuoted(workingDirectory)) && \(invocation) \"$(cat \(file))\"; rm -f \(file)"
    }

    /// `cd '<dir>' && '<claude>' --resume '<sid>'`
    static func resumeCommand(
        claudePath: String,
        workingDirectory: String,
        sessionID: String
    ) -> String {
        "cd \(shellQuoted(workingDirectory)) && \(shellQuoted(claudePath)) --resume \(shellQuoted(sessionID))"
    }

    /// Backslashes before quotes — reversing the order corrupts the escapes.
    static func escapedForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Single-quote wrapping; embedded single quotes become `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
