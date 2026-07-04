import Foundation
import os

/// v1's one dispatcher: runs `claude -p <prompt>` headlessly in a user-chosen
/// working directory, streaming stream-json events into the card's log.
struct ClaudeCodeDispatcher: Dispatcher {
    let id = "claude-code"
    let displayName = "Claude Code"

    var paramSpecs: [DispatcherParamSpec] {
        [
            DispatcherParamSpec(id: "workingDirectory", label: "Working Directory", kind: .directory, required: true),
            DispatcherParamSpec(id: "extraFlags", label: "Extra CLI Flags", kind: .string, required: false),
        ]
    }

    private let locator: ClaudeBinaryLocator

    init(locator: ClaudeBinaryLocator = ClaudeBinaryLocator()) {
        self.locator = locator
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

        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "acceptEdits",
            "--max-turns", "25",
        ]
        arguments += Self.tokenizeFlags(params["extraFlags"] ?? "")

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
                        return Self.outcome(
                            exitCode: exitCode,
                            result: s.result,
                            stderrTail: Self.tail(of: s.stderr))
                    }
                    guard let outcome else { return }
                    if let text = outcome.resultText { onEvent(.log(text)) }
                    resumeOnce(.success(outcome))
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    let events: [ClaudeEvent] = state.withLock { s in
                        let parsed = chunk.isEmpty ? s.parser.finish() : s.parser.consume(chunk)
                        if chunk.isEmpty { s.stdoutDone = true }
                        for case .result(let runResult) in parsed { s.result = runResult }
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

                do {
                    try box.run()
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

    /// Success rule (verified against CLI 2.1.200): exit 0 AND a result event
    /// was seen AND is_error is false. Note subtype can be "success" while
    /// is_error is true (API errors), and a SIGTERM'd run emits NO result
    /// event at all — that is "cancelled or crashed".
    static func outcome(exitCode: Int, result: ClaudeRunResult?, stderrTail: String) -> DispatchResult {
        guard let result else {
            var text = "cancelled or crashed (exit \(exitCode))"
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
    var stdoutDone = false
    var stderrDone = false
    var exitCode: Int?
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
