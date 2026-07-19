import Foundation
import os

/// v1's one dispatcher: runs `claude -p <prompt>` headlessly in a user-chosen
/// working directory, streaming stream-json events into the card's log.
struct ClaudeCodeDispatcher: Dispatcher {
    let id = "claude-code"
    let displayName = "Claude Code"

    /// Verified against CLI 2.1.200 (`--permission-mode` rejects anything else).
    static let permissionModes = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    static let defaultPermissionMode = "acceptEdits"
    static let maxTurnsRange = 1...200
    static let defaultMaxTurns = 25

    var paramSpecs: [DispatcherParamSpec] {
        [
            DispatcherParamSpec(id: "workingDirectory", label: "Working Directory", kind: .directory, required: true),
            DispatcherParamSpec(
                id: "permissionMode", label: "Permission Mode",
                kind: .choice(options: Self.permissionModes), required: false,
                defaultValue: Self.defaultPermissionMode),
            DispatcherParamSpec(
                id: "maxTurns", label: "Max Turns",
                kind: .integer(range: Self.maxTurnsRange), required: false,
                defaultValue: String(Self.defaultMaxTurns)),
            // Visible (not hidden state) so a follow-up card's resume target
            // can be seen and cleared in the generic param UI.
            DispatcherParamSpec(id: "resumeSessionID", label: "Resume Session ID", kind: .string, required: false),
            DispatcherParamSpec(id: "extraFlags", label: "Extra CLI Flags", kind: .string, required: false),
        ]
    }

    /// No stream activity for this long → the run is treated as stalled and
    /// terminated. Claude runs can legitimately take a long time, but a
    /// healthy run streams events continuously — silence is the failure
    /// signal (permission wait, auth hang, dead MCP server, …).
    static let defaultStallTimeout: TimeInterval = 300

    private let locator: ClaudeBinaryLocator
    private let stallTimeout: TimeInterval
    private let watchdogInterval: TimeInterval

    init(
        locator: ClaudeBinaryLocator = ClaudeBinaryLocator(),
        stallTimeout: TimeInterval = ClaudeCodeDispatcher.defaultStallTimeout,
        watchdogInterval: TimeInterval = 30
    ) {
        self.locator = locator
        self.stallTimeout = stallTimeout
        self.watchdogInterval = watchdogInterval
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
        guard let binary = locator.locate() else {
            throw DispatcherError.executableNotFound("claude CLI (\(ClaudeBinaryLocator.requiredMajorVersion).x or newer)")
        }
        try Task.checkCancellation()

        let arguments = try Self.arguments(prompt: prompt, params: params)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary.path)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        // claude shells out (Bash tool, ripgrep, git) — give it a sane PATH
        // regardless of how Voxi was launched.
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        // Without this, claude stalls 3s waiting on stdin and warns to stderr.
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let box = ProcessBox(process)
        let state = OSAllocatedUnfairLock(initialState: RunState())

        onEvent(.log("claude \(binary.version) — \(cwd)"))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeGuard = OSAllocatedUnfairLock(initialState: false)
                @Sendable func resumeOnce(_ result: Result<DispatchResult, Error>) {
                    let first = resumeGuard.withLock { resumed in
                        defer { resumed = true }
                        return !resumed
                    }
                    guard first else { return }
                    continuation.resume(with: result)
                }

                @Sendable func forward(_ events: [ClaudeEvent]) {
                    for event in events {
                        switch event {
                        case .initialized(_, let model):
                            onEvent(.log("session started (model: \(model))"))
                        case .assistantText(let text):
                            onEvent(.log(text))
                        case .toolUse(let name, let summary):
                            onEvent(.log(summary.map { "\(name): \($0)" } ?? name))
                            onEvent(.activity(name))
                        case .result:
                            break   // folded into the final log line below
                        }
                    }
                }

                // Resume only after stdout hit EOF, stderr hit EOF, AND the
                // process exited — otherwise late-buffered events are lost.
                @Sendable func maybeFinish() {
                    let outcome: DispatchResult? = state.withLock { s in
                        guard s.stdoutDone, s.stderrDone, let exitCode = s.exitCode else { return nil }
                        var out = Self.outcome(
                            exitCode: exitCode,
                            result: s.result,
                            stderrTail: Self.tail(of: s.stderr),
                            stalledAfter: s.stalled ? stallTimeout : nil)
                        out.sessionID = s.sessionID
                        return out
                    }
                    guard let outcome else { return }
                    if let text = outcome.resultText { onEvent(.log(text)) }
                    resumeOnce(.success(outcome))
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    let events: [ClaudeEvent] = state.withLock { s in
                        let parsed = chunk.isEmpty ? s.parser.finish() : s.parser.consume(chunk)
                        if chunk.isEmpty { s.stdoutDone = true } else { s.lastActivity = .now() }
                        for event in parsed {
                            switch event {
                            case .result(let runResult): s.result = runResult
                            case .initialized(let sessionID, _): s.sessionID = sessionID
                            default: break
                            }
                        }
                        return parsed
                    }
                    forward(events)
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        maybeFinish()
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    state.withLock { s in
                        if chunk.isEmpty {
                            s.stderrDone = true
                        } else {
                            s.stderr.append(chunk)
                            s.lastActivity = .now()
                        }
                    }
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        maybeFinish()
                    }
                }

                process.terminationHandler = { finished in
                    let exitCode = finished.terminationReason == .uncaughtSignal
                        ? 128 + Int(finished.terminationStatus)   // shell convention, e.g. SIGTERM -> 143
                        : Int(finished.terminationStatus)
                    state.withLock { $0.exitCode = exitCode }
                    maybeFinish()
                }

                // Stall watchdog: periodically checks stream activity; a run
                // that stays silent past stallTimeout is terminated through
                // the same SIGTERM/SIGKILL path as a user cancel, and the
                // normal EOF+exit completion then resumes with a stall
                // message. Rescheduling stops once the process has exited.
                @Sendable func scheduleWatchdog() {
                    DispatchQueue.global().asyncAfter(deadline: .now() + watchdogInterval) {
                        enum Verdict { case done, stalled, healthy }
                        let verdict: Verdict = state.withLock { s in
                            guard s.exitCode == nil else { return .done }
                            let silentNanos = DispatchTime.now().uptimeNanoseconds - s.lastActivity.uptimeNanoseconds
                            guard Double(silentNanos) / 1_000_000_000 > stallTimeout else { return .healthy }
                            s.stalled = true
                            return .stalled
                        }
                        switch verdict {
                        case .done:
                            break
                        case .stalled:
                            onEvent(.log("no output for \(Int(stallTimeout))s — terminating stalled run"))
                            box.cancel()
                        case .healthy:
                            scheduleWatchdog()
                        }
                    }
                }

                do {
                    try box.run()
                    scheduleWatchdog()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    resumeOnce(.failure(DispatcherError.spawnFailed(error.localizedDescription)))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Pure logic (unit-tested)

    /// Builds the claude argument list from the card's params. Absent params
    /// fall back to the spec defaults; present-but-invalid ones fail loud.
    static func arguments(prompt: String, params: [String: String]) throws -> [String] {
        let modeRaw = params["permissionMode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let permissionMode = modeRaw.isEmpty ? defaultPermissionMode : modeRaw
        guard permissionModes.contains(permissionMode) else {
            throw DispatcherError.invalidParams(
                "unknown permission mode: \(permissionMode) (allowed: \(permissionModes.joined(separator: ", ")))")
        }
        let turnsRaw = params["maxTurns"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let maxTurns: Int
        if turnsRaw.isEmpty {
            maxTurns = defaultMaxTurns
        } else if let parsed = Int(turnsRaw), maxTurnsRange.contains(parsed) {
            maxTurns = parsed
        } else {
            throw DispatcherError.invalidParams(
                "max turns must be a number from \(maxTurnsRange.lowerBound) to \(maxTurnsRange.upperBound), got: \(turnsRaw)")
        }

        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode,
            "--max-turns", String(maxTurns),
        ]
        if let resume = params["resumeSessionID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resume.isEmpty {
            arguments += ["--resume", resume]
        }
        arguments += tokenizeFlags(params["extraFlags"] ?? "")
        return arguments
    }

    /// Success rule (verified against CLI 2.1.200): exit 0 AND a result event
    /// was seen AND is_error is false. Note subtype can be "success" while
    /// is_error is true (API errors), and a SIGTERM'd run emits NO result
    /// event at all — that is "cancelled or crashed" (or a watchdog stall,
    /// when `stalledAfter` is set).
    static func outcome(
        exitCode: Int, result: ClaudeRunResult?, stderrTail: String,
        stalledAfter: TimeInterval? = nil
    ) -> DispatchResult {
        guard let result else {
            var text: String
            if let stalledAfter {
                text = "stalled — no output for \(Int(stalledAfter))s, terminated (exit \(exitCode))"
            } else {
                text = "cancelled or crashed (exit \(exitCode))"
            }
            if !stderrTail.isEmpty { text += " — \(stderrTail)" }
            return DispatchResult(success: false, exitCode: exitCode, resultText: text)
        }
        let stats = statsSuffix(of: result)
        if exitCode == 0 && !result.isError {
            let text = result.resultText ?? "Completed"
            return DispatchResult(success: true, exitCode: exitCode, resultText: "\(text) [\(stats)]")
        }
        let reason = result.resultText
            ?? "claude failed (\(result.subtype ?? "unknown"), exit \(exitCode))"
        return DispatchResult(success: false, exitCode: exitCode, resultText: "\(reason) [\(stats)]")
    }

    /// "cost $0.4264, 8.7s, 2 turns" (+ permission-denial warning when any).
    static func statsSuffix(of result: ClaudeRunResult) -> String {
        var parts: [String] = []
        if let cost = result.totalCostUSD {
            parts.append(String(format: "cost $%.4f", cost))
        }
        if let durationMS = result.durationMS {
            parts.append(String(format: "%.1fs", Double(durationMS) / 1000))
        }
        if let turns = result.numTurns {
            parts.append("\(turns) turn\(turns == 1 ? "" : "s")")
        }
        if result.permissionDenialCount > 0 {
            parts.append("\(result.permissionDenialCount) permission denial\(result.permissionDenialCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    /// Whitespace tokenization of the user's extra CLI flags (no quoting).
    static func tokenizeFlags(_ flags: String) -> [String] {
        flags.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func tail(of data: Data, maxLength: Int = 400) -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
        return text.count <= maxLength ? text : "…" + String(text.suffix(maxLength))
    }
}

// MARK: - Run plumbing

private struct RunState: Sendable {
    var parser = StreamJSONParser()
    var stderr = Data()
    var result: ClaudeRunResult?
    var sessionID: String?
    var stdoutDone = false
    var stderrDone = false
    var exitCode: Int?
    /// Monotonic clock of the last stdout/stderr chunk; the watchdog compares
    /// against this to decide a run has gone silent.
    var lastActivity: DispatchTime = .now()
    var stalled = false
}

/// Process is not Sendable; all access is funneled through this box whose
/// lock also closes the cancel-before-run race (cancellation arriving between
/// spawn and the onCancel handler firing).
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = OSAllocatedUnfairLock(initialState: false)   // cancelled?

    init(_ process: Process) {
        self.process = process
    }

    func run() throws {
        try lock.withLock { cancelled in
            try process.run()
            if cancelled { terminateWithGrace() }
        }
    }

    func cancel() {
        lock.withLock { cancelled in
            guard !cancelled else { return }
            cancelled = true
            terminateWithGrace()
        }
    }

    /// SIGTERM first (claude exits 143 with no result event), SIGKILL if it
    /// hasn't died after a 3s grace period.
    private func terminateWithGrace() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
