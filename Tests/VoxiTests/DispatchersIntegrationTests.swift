import Foundation
import Testing
import os
@testable import Voxi

/// End-to-end run against the real claude CLI. Skipped by default so normal
/// test runs stay hermetic and free; enable with
/// `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 xcodebuild ... test`.
@Suite struct DispatchersIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXI_CLAUDE_INTEGRATION"] == "1"))
    func runsTrivialPromptHeadlessly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-claude-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let events = OSAllocatedUnfairLock(initialState: [DispatchEvent]())
        let result = try await ClaudeCodeDispatcher().execute(
            prompt: "Reply with exactly the single word: pong",
            params: [
                "workingDirectory": tempDir.path,
                "extraFlags": "--max-turns 1",   // appended after defaults; last flag wins
            ],
            onEvent: { event in events.withLock { $0.append(event) } })

        let logs = events.withLock { captured in
            captured.compactMap { if case .log(let line) = $0 { line } else { nil } }
        }
        print("VOXI_CLAUDE_INTEGRATION logs:\n" + logs.joined(separator: "\n"))
        print("VOXI_CLAUDE_INTEGRATION result: success=\(result.success) exit=\(String(describing: result.exitCode)) text=\(result.resultText ?? "nil")")

        #expect(result.success)
        #expect(result.exitCode == 0)
        #expect(result.resultText?.contains("cost $") == true)
        #expect(logs.contains { $0.contains("session started") })
    }
}
