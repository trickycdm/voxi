import Foundation

/// Hand-off dispatcher: opens a new terminal window (iTerm2, Terminal.app
/// fallback) running interactive `claude` with the card's prompt, then
/// succeeds immediately. No logs or session tracking after the hand-off —
/// deliberately no `sessionID` in the result, since the interactive session's
/// id is unknowable, so Follow up / resume actions never appear on these cards.
struct ClaudeCodeITermDispatcher: Dispatcher {
    static let dispatcherID = "claude-code-iterm"

    let id = ClaudeCodeITermDispatcher.dispatcherID
    let displayName = "Claude Code (iTerm)"

    private let locator: ClaudeBinaryLocator

    init(locator: ClaudeBinaryLocator = ClaudeBinaryLocator()) {
        self.locator = locator
    }

    // No permissionMode/maxTurns (the user drives the session live) and no
    // extraFlags (naïve tokenization would cross the shell-quoting boundary).
    var paramSpecs: [DispatcherParamSpec] {
        [
            DispatcherParamSpec(id: "workingDirectory", label: "Working Directory", kind: .directory, required: true),
            // Lets a follow-up card from a headless run resume interactively.
            DispatcherParamSpec(id: "resumeSessionID", label: "Resume Session ID", kind: .string, required: false),
        ]
    }

    func execute(
        prompt: String,
        params: [String: String],
        onEvent: @escaping @Sendable (DispatchEvent) -> Void
    ) async throws -> DispatchResult {
        guard let cwd = params["workingDirectory"], !cwd.isEmpty else {
            throw DispatcherError.invalidParams("workingDirectory is required")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DispatcherError.invalidParams("working directory does not exist: \(cwd)")
        }
        // The located absolute path, not the login shell's PATH lookup — the
        // login shell can resolve a stale claude (see ClaudeBinaryLocator).
        guard let binary = locator.locate() else {
            throw DispatcherError.executableNotFound("claude CLI (\(ClaudeBinaryLocator.requiredMajorVersion).x or newer)")
        }
        try Task.checkCancellation()

        let promptsDir = Self.promptsDirectory()
        Self.sweepStalePromptFiles(in: promptsDir)
        let promptFile: URL
        do {
            promptFile = try Self.writePromptFile(prompt, in: promptsDir)
        } catch {
            throw DispatcherError.spawnFailed("could not write prompt file: \(error.localizedDescription)")
        }

        let resume = params["resumeSessionID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = TerminalLauncher.launchCommand(
            claudePath: binary.path,
            workingDirectory: cwd,
            promptFilePath: promptFile.path,
            resumeSessionID: resume.isEmpty ? nil : resume)

        // NSAppleScript is main-thread-only.
        let app = try await MainActor.run { try TerminalLauncher.launch(command: command) }

        onEvent(.log("Opened interactive claude \(binary.version) in \(app.displayName) — \(cwd)"))
        return DispatchResult(success: true, exitCode: nil, resultText: "Opened in \(app.displayName)")
    }

    // MARK: - Prompt temp files (unit-tested with an injected directory)

    /// The shell command `rm`s the file after claude exits; the sweep on each
    /// dispatch catches files orphaned by windows closed early.
    static func promptsDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxiTermPrompts", isDirectory: true)
    }

    static func writePromptFile(_ prompt: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".txt")
        try prompt.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func sweepStalePromptFiles(
        in directory: URL,
        olderThan maxAge: TimeInterval = 86_400,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > maxAge {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
