import Foundation
import Testing
@testable import Voxi

// MARK: - Real captured stream-json lines (claude CLI 2.1.200 on this machine,
// scratchpad/research/cli-test/out*.ndjson). Long array fields trimmed on the
// init line; every other line is verbatim.

private enum Captured {
    static let initLine = #"{"type":"system","subtype":"init","cwd":"/private/tmp/cli-test","session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","tools":["Task","Bash","Edit","Read","Write"],"mcp_servers":[],"model":"claude-fable-5","permissionMode":"acceptEdits","slash_commands":[],"apiKeySource":"none","output_style":"default","agents":["general-purpose"],"uuid":"1c1bfb98-16e5-4d09-b31c-a51000a86ed3"}"#

    static let rateLimitLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1783159800,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false},"uuid":"d1367d5e-69bf-4480-bad8-e70edb88ecf5","session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d"}"#

    static let thinkingLine = #"{"type":"assistant","message":{"model":"claude-fable-5","id":"msg_019kn4A3ErB4A1Vvy1esFSD5","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"CAIS5wEKYggPGAIqQLuRm2VT"}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":9386,"output_tokens":2},"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","uuid":"2f96b1d1-4661-4302-a204-eb0e356a744c","request_id":"req_011CcgTJiyUnnaV1LUcunKtr"}"#

    static let toolUseWriteLine = #"{"type":"assistant","message":{"model":"claude-fable-5","id":"msg_019kn4A3ErB4A1Vvy1esFSD5","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01HTMVEdUan7uTDR37gZCjpX","name":"Write","input":{"file_path":"/private/tmp/cli-test/hello.txt","content":"hello\n"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":9386,"cache_creation_input_tokens":4750,"cache_read_input_tokens":15077,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4750},"output_tokens":3,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","uuid":"b66c73c8-f659-4568-bf15-ab1789f4cdde","request_id":"req_011CcgTJiyUnnaV1LUcunKtr"}"#

    static let toolUseBashLine = #"{"type":"assistant","message":{"model":"claude-fable-5","id":"msg_019STzvuaUZyUfoWVxy4X1n4","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_012kfmMRjYahv94q7PHKiQn8","name":"Bash","input":{"command":"sleep 1","description":"Sleep for 1 second (run 1 of 3)"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":9386,"cache_creation_input_tokens":1625,"cache_read_input_tokens":18206,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1625},"output_tokens":4,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"b1cacbdf-32f5-479b-97ed-4a869575dda8","uuid":"3c6666cf-c483-4b9b-a146-c1046e486022","request_id":"req_011CcgTNxUSttibp3T1fBCmq"}"#

    static let toolResultLine = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01HTMVEdUan7uTDR37gZCjpX","type":"tool_result","content":"File created successfully at: /private/tmp/cli-test/hello.txt"}]},"parent_tool_use_id":null,"session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","uuid":"7b888547-65ad-4e20-9cf2-11791c1c1c1c"}"#

    static let textLine = #"{"type":"assistant","message":{"model":"claude-fable-5","id":"msg_0171z7newP51y2cV3uUMY7ke","type":"message","role":"assistant","content":[{"type":"text","text":"Done — I created `hello.txt` in the working directory containing the word \"hello\"."}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":9642,"cache_read_input_tokens":19827,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":9642},"output_tokens":2,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null,"context_management":null},"parent_tool_use_id":null,"session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","uuid":"ac4db1a2-6933-4cb5-afe6-c7fbfa825c64","request_id":"req_011CcgTK9conUVnDwXBtTTbo"}"#

    static let resultSuccessLine = #"{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"duration_ms":8660,"duration_api_ms":9486,"ttft_ms":3496,"ttft_stream_ms":2930,"time_to_request_ms":24,"num_turns":2,"result":"Done — I created `hello.txt` in the working directory containing the word \"hello\".","stop_reason":"end_turn","session_id":"ab4694a7-7cfd-41d4-9f9b-fac26ce2930d","total_cost_usd":0.42642399999999997,"usage":{"input_tokens":9388,"cache_creation_input_tokens":14392,"cache_read_input_tokens":34904,"output_tokens":184,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":14392,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":27,"cache_read_input_tokens":19827,"cache_creation_input_tokens":9642,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":9642},"type":"message"}],"speed":"standard"},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":535,"outputTokens":13,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.0006,"contextWindow":200000,"maxOutputTokens":32000},"claude-fable-5":{"inputTokens":9388,"outputTokens":184,"cacheReadInputTokens":34904,"cacheCreationInputTokens":14392,"webSearchRequests":0,"costUSD":0.425824,"contextWindow":1000000,"maxOutputTokens":64000}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","uuid":"a0a8b9c8-f286-4799-922e-e29ac0564a84"}"#

    /// Note: NO "result" key at all — the parser must tolerate absent as well
    /// as JSON-null result text.
    static let resultMaxTurnsLine = #"{"type":"result","subtype":"error_max_turns","duration_ms":10895,"duration_api_ms":10598,"is_error":true,"num_turns":2,"stop_reason":"tool_use","session_id":"b1cacbdf-32f5-479b-97ed-4a869575dda8","total_cost_usd":0.16568400000000003,"usage":{"input_tokens":9386,"cache_creation_input_tokens":1625,"cache_read_input_tokens":18206,"output_tokens":410,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":1625,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[],"speed":"standard"},"modelUsage":{},"permission_denials":[],"terminal_reason":"max_turns","fast_mode_state":"off","uuid":"23099bf4-2db2-46f9-addf-3c26b6e3c105","errors":["Reached maximum number of turns (1)"]}"#

    /// subtype "success" while is_error is true (404 bad model) — the success
    /// rule must branch on is_error, never subtype.
    static let resultBadModelLine = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"duration_ms":667,"duration_api_ms":0,"num_turns":1,"result":"There's an issue with the selected model (no-such-model). It may not exist or you may not have access to it. Run --model to pick a different model.","stop_reason":"stop_sequence","session_id":"0a4d8d99-ef93-4499-9084-39b2c92d24e0","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard"},"modelUsage":{},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","uuid":"8bf6e05d-1e03-46f1-8ee7-20b839819dc3"}"#

    static let statusLine = #"{"type":"system","subtype":"status","status":"requesting","uuid":"ba624c21-ef8a-4d11-9285-b328656dabe6","session_id":"23dd665a-e0c0-43e5-8099-08f8f0c0ba27"}"#

    static let thinkingTokensLine = #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"uuid":"6b12acd6-7760-49ec-835d-539d9fbec2f0","session_id":"b1cacbdf-32f5-479b-97ed-4a869575dda8"}"#

    static let streamEventLine = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello!"}},"session_id":"23dd665a-e0c0-43e5-8099-08f8f0c0ba27","parent_tool_use_id":null,"uuid":"6eaca670-2292-4a5f-9011-f70cb61f3734"}"#
}

private func parse(_ line: String) -> [ClaudeEvent] {
    StreamJSONParser.events(fromLine: Data(line.utf8))
}

// MARK: - Parser: event decoding against real lines

@Suite struct StreamJSONParserEventTests {
    @Test func decodesSystemInit() {
        let events = parse(Captured.initLine)
        #expect(events == [.initialized(sessionID: "ab4694a7-7cfd-41d4-9f9b-fac26ce2930d", model: "claude-fable-5")])
    }

    @Test func decodesAssistantText() {
        let events = parse(Captured.textLine)
        #expect(events == [.assistantText("Done — I created `hello.txt` in the working directory containing the word \"hello\".")])
    }

    @Test func decodesToolUseWithFilePathSummary() {
        let events = parse(Captured.toolUseWriteLine)
        #expect(events == [.toolUse(name: "Write", summary: "/private/tmp/cli-test/hello.txt")])
    }

    @Test func decodesToolUseWithCommandSummary() {
        // Bash has both "command" and "description" — command wins.
        let events = parse(Captured.toolUseBashLine)
        #expect(events == [.toolUse(name: "Bash", summary: "sleep 1")])
    }

    @Test func skipsThinkingBlocks() {
        #expect(parse(Captured.thinkingLine).isEmpty)
    }

    @Test func decodesSuccessResult() throws {
        let events = parse(Captured.resultSuccessLine)
        guard case .result(let result)? = events.first else {
            Issue.record("expected result event, got \(events)")
            return
        }
        #expect(!result.isError)
        #expect(result.subtype == "success")
        #expect(result.resultText == "Done — I created `hello.txt` in the working directory containing the word \"hello\".")
        #expect(result.totalCostUSD == 0.42642399999999997)
        #expect(result.numTurns == 2)
        #expect(result.durationMS == 8660)
        #expect(result.permissionDenialCount == 0)
    }

    @Test func decodesMaxTurnsResultWithMissingResultText() throws {
        let events = parse(Captured.resultMaxTurnsLine)
        guard case .result(let result)? = events.first else {
            Issue.record("expected result event, got \(events)")
            return
        }
        #expect(result.isError)
        #expect(result.subtype == "error_max_turns")
        #expect(result.resultText == nil)
        #expect(result.totalCostUSD == 0.16568400000000003)
    }

    @Test func decodesApiErrorResultWithSuccessSubtype() throws {
        let events = parse(Captured.resultBadModelLine)
        guard case .result(let result)? = events.first else {
            Issue.record("expected result event, got \(events)")
            return
        }
        #expect(result.subtype == "success")
        #expect(result.isError)   // never trust subtype alone
        #expect(result.resultText?.contains("no-such-model") == true)
    }

    @Test func silentlySkipsUnknownAndHousekeepingEvents() {
        #expect(parse(Captured.rateLimitLine).isEmpty)
        #expect(parse(Captured.statusLine).isEmpty)
        #expect(parse(Captured.thinkingTokensLine).isEmpty)
        #expect(parse(Captured.streamEventLine).isEmpty)
        #expect(parse(Captured.toolResultLine).isEmpty)
        #expect(parse(#"{"type":"some_future_event","payload":{"x":1}}"#).isEmpty)
        #expect(parse(#"{"type":"system","subtype":"some_future_subtype"}"#).isEmpty)
        #expect(parse("not json at all").isEmpty)
        #expect(parse("").isEmpty)
    }

    @Test func toolSummaryFallsBackThroughPriorityKeys() {
        #expect(StreamJSONParser.toolSummary(from: .object(["description": .string("list files")])) == "list files")
        #expect(StreamJSONParser.toolSummary(from: .object(["count": .number(3)])) == nil)
        #expect(StreamJSONParser.toolSummary(from: nil) == nil)
        // Long values are collapsed to one line and truncated.
        let long = String(repeating: "x", count: 500) + "\ny"
        let summary = StreamJSONParser.toolSummary(from: .object(["command": .string(long)]))
        #expect(summary?.count == 121)   // 120 + ellipsis
        #expect(summary?.contains("\n") == false)
    }
}

// MARK: - Parser: incremental line buffering

@Suite struct StreamJSONParserBufferingTests {
    @Test func splitsLinesAcrossArbitraryChunks() {
        var parser = StreamJSONParser()
        let data = Data((Captured.initLine + "\n" + Captured.textLine + "\n").utf8)
        var events: [ClaudeEvent] = []
        // Feed in pathological 7-byte chunks.
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 7, limitedBy: data.endIndex) ?? data.endIndex
            events.append(contentsOf: parser.consume(data.subdata(in: index..<end)))
            index = end
        }
        events.append(contentsOf: parser.finish())
        #expect(events.count == 2)
        #expect(events.first == .initialized(sessionID: "ab4694a7-7cfd-41d4-9f9b-fac26ce2930d", model: "claude-fable-5"))
    }

    @Test func multipleLinesInOneChunk() {
        var parser = StreamJSONParser()
        let chunk = Data((Captured.initLine + "\n" + Captured.rateLimitLine + "\n" + Captured.toolUseBashLine + "\n").utf8)
        let events = parser.consume(chunk)
        #expect(events == [
            .initialized(sessionID: "ab4694a7-7cfd-41d4-9f9b-fac26ce2930d", model: "claude-fable-5"),
            .toolUse(name: "Bash", summary: "sleep 1"),
        ])
    }

    @Test func finishParsesUnterminatedTrailingLine() {
        var parser = StreamJSONParser()
        #expect(parser.consume(Data(Captured.textLine.utf8)).isEmpty)   // no newline yet
        let events = parser.finish()
        #expect(events.count == 1)
        #expect(parser.finish().isEmpty)   // buffer cleared
    }

    @Test func toleratesBlankAndCRLFLines() {
        var parser = StreamJSONParser()
        let chunk = Data(("\n\r\n" + Captured.initLine + "\r\n\n").utf8)
        let events = parser.consume(chunk)
        #expect(events.count == 1)
    }

    @Test func replaysFullCapturedRun() {
        // The complete out1.ndjson event sequence (2-turn Write run).
        let lines = [
            Captured.initLine, Captured.rateLimitLine, Captured.thinkingLine,
            Captured.toolUseWriteLine, Captured.toolResultLine, Captured.textLine,
            Captured.resultSuccessLine,
        ]
        var parser = StreamJSONParser()
        var events = parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        events.append(contentsOf: parser.finish())
        #expect(events.count == 4)   // init, tool_use, text, result
        guard case .result(let result)? = events.last else {
            Issue.record("last event should be result")
            return
        }
        #expect(!result.isError)
    }
}

// MARK: - Success rule matrix

@Suite struct ClaudeOutcomeTests {
    private func runResult(isError: Bool, text: String? = "done") -> ClaudeRunResult {
        ClaudeRunResult(
            subtype: isError ? "error" : "success", isError: isError, resultText: text,
            totalCostUSD: 0.4264, numTurns: 2, durationMS: 8660, permissionDenialCount: 0)
    }

    @Test func exitZeroWithCleanResultSucceeds() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 0, result: runResult(isError: false), stderrTail: "")
        #expect(outcome.success)
        #expect(outcome.exitCode == 0)
        #expect(outcome.resultText?.contains("done") == true)
        // Final text must carry cost and duration.
        #expect(outcome.resultText?.contains("$0.4264") == true)
        #expect(outcome.resultText?.contains("8.7s") == true)
    }

    @Test func exitZeroWithIsErrorFails() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 0, result: runResult(isError: true), stderrTail: "")
        #expect(!outcome.success)
    }

    @Test func nonzeroExitWithCleanResultFails() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 1, result: runResult(isError: false), stderrTail: "")
        #expect(!outcome.success)
    }

    @Test func nonzeroExitWithErrorResultFails() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 1, result: runResult(isError: true), stderrTail: "")
        #expect(!outcome.success)
        #expect(outcome.exitCode == 1)
    }

    @Test func missingResultEventIsCancelledOrCrashed() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 143, result: nil, stderrTail: "")
        #expect(!outcome.success)
        #expect(outcome.resultText?.contains("cancelled or crashed") == true)
        #expect(outcome.resultText?.contains("143") == true)
    }

    @Test func missingResultEventEvenWithExitZeroFails() {
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 0, result: nil, stderrTail: "")
        #expect(!outcome.success)
        #expect(outcome.resultText?.contains("cancelled or crashed") == true)
    }

    @Test func stderrTailSurfacesOnCrash() {
        let outcome = ClaudeCodeDispatcher.outcome(
            exitCode: 1, result: nil, stderrTail: "error: unknown option '--bogus-flag'")
        #expect(!outcome.success)
        #expect(outcome.resultText?.contains("--bogus-flag") == true)
    }

    @Test func maxTurnsFailureFallsBackToSubtypeText() {
        let result = ClaudeRunResult(
            subtype: "error_max_turns", isError: true, resultText: nil,
            totalCostUSD: 0.1657, numTurns: 2, durationMS: 10895, permissionDenialCount: 0)
        let outcome = ClaudeCodeDispatcher.outcome(exitCode: 1, result: result, stderrTail: "")
        #expect(!outcome.success)
        #expect(outcome.resultText?.contains("error_max_turns") == true)
        #expect(outcome.resultText?.contains("$0.1657") == true)
    }

    @Test func statsIncludePermissionDenials() {
        let result = ClaudeRunResult(
            subtype: "success", isError: false, resultText: "ok",
            totalCostUSD: 0.01, numTurns: 1, durationMS: 1000, permissionDenialCount: 2)
        let stats = ClaudeCodeDispatcher.statsSuffix(of: result)
        #expect(stats.contains("2 permission denials"))
        #expect(stats.contains("1 turn"))
    }
}

// MARK: - Dispatcher params & flags

@Suite struct ClaudeCodeDispatcherParamTests {
    @Test func tokenizesExtraFlagsOnWhitespace() {
        #expect(ClaudeCodeDispatcher.tokenizeFlags("--model sonnet  --max-budget-usd 2.00") ==
            ["--model", "sonnet", "--max-budget-usd", "2.00"])
        #expect(ClaudeCodeDispatcher.tokenizeFlags("") == [])
        #expect(ClaudeCodeDispatcher.tokenizeFlags("   ") == [])
        #expect(ClaudeCodeDispatcher.tokenizeFlags("\t--verbose\n--bare ") == ["--verbose", "--bare"])
    }

    @Test func declaresTheFiveParams() {
        let specs = ClaudeCodeDispatcher().paramSpecs
        #expect(specs.map(\.id) == [
            "workingDirectory", "permissionMode", "maxTurns", "resumeSessionID", "extraFlags",
        ])
        #expect(specs[0].required)
        if case .directory = specs[0].kind {} else { Issue.record("workingDirectory should be a directory param") }
        // Only the working directory is required; everything else defaults.
        #expect(specs.dropFirst().allSatisfy { !$0.required })
        #expect(specs[1].defaultValue == "acceptEdits")
        if case .choice(let options) = specs[1].kind {
            #expect(options == ClaudeCodeDispatcher.permissionModes)
        } else { Issue.record("permissionMode should be a choice param") }
        #expect(specs[2].defaultValue == "25")
        if case .integer(let range) = specs[2].kind {
            #expect(range == ClaudeCodeDispatcher.maxTurnsRange)
        } else { Issue.record("maxTurns should be an integer param") }
    }

    @Test func rejectsMissingWorkingDirectory() async {
        await #expect(throws: DispatcherError.self) {
            _ = try await ClaudeCodeDispatcher().execute(prompt: "x", params: [:], onEvent: { _ in })
        }
    }

    @Test func rejectsNonexistentWorkingDirectory() async {
        await #expect(throws: DispatcherError.self) {
            _ = try await ClaudeCodeDispatcher().execute(
                prompt: "x",
                params: ["workingDirectory": "/nonexistent/voxi-test-\(UUID().uuidString)"],
                onEvent: { _ in })
        }
    }

    @Test func throwsWhenNoClaudeBinaryFound() async throws {
        let suite = "voxi-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let locator = ClaudeBinaryLocator(
            defaults: defaults, probePaths: [],
            versionOutput: { _ in nil }, loginShellLookup: { nil }, fileExists: { _ in false })
        await #expect(throws: DispatcherError.self) {
            _ = try await ClaudeCodeDispatcher(locator: locator).execute(
                prompt: "x",
                params: ["workingDirectory": FileManager.default.temporaryDirectory.path],
                onEvent: { _ in })
        }
    }
}

// MARK: - Binary locator

@Suite struct ClaudeBinaryLocatorTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "voxi-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func parsesRealVersionOutput() {
        let parsed = ClaudeBinaryLocator.parseVersion("2.1.200 (Claude Code)")
        #expect(parsed?.major == 2)
        #expect(parsed?.display == "2.1.200")
        #expect(ClaudeBinaryLocator.parseVersion("1.0.113 (Claude Code)")?.major == 1)
        #expect(ClaudeBinaryLocator.parseVersion("nonsense") == nil)
        #expect(ClaudeBinaryLocator.parseVersion("") == nil)
    }

    @Test func skipsStaleOneDotXInstallAndPersistsFirstValid() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        // Mirrors this machine: homebrew path holds a stale 1.0.113.
        let versions = [
            "/stale/claude": "1.0.113 (Claude Code)",
            "/good/claude": "2.1.200 (Claude Code)",
        ]
        let locator = ClaudeBinaryLocator(
            defaults: defaults,
            probePaths: ["/missing/claude", "/stale/claude", "/good/claude"],
            versionOutput: { versions[$0] },
            loginShellLookup: { "/stale/claude" },
            fileExists: { $0 != "/missing/claude" })
        let binary = locator.probe()
        #expect(binary == ClaudeBinaryLocator.Binary(path: "/good/claude", version: "2.1.200"))
        #expect(defaults.string(forKey: ClaudeBinaryLocator.pathDefaultsKey) == "/good/claude")
        #expect(defaults.string(forKey: ClaudeBinaryLocator.versionDefaultsKey) == "2.1.200")
        // locate() now serves the cached answer.
        #expect(locator.locate() == binary)
    }

    @Test func probesLoginShellPathLast() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let locator = ClaudeBinaryLocator(
            defaults: defaults,
            probePaths: ["/missing/claude"],
            versionOutput: { $0 == "/shell/claude" ? "2.0.0 (Claude Code)" : nil },
            loginShellLookup: { "/shell/claude" },
            fileExists: { $0 == "/shell/claude" })
        #expect(locator.probe()?.path == "/shell/claude")
    }

    @Test func returnsNilWhenOnlyStaleBinariesExist() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let locator = ClaudeBinaryLocator(
            defaults: defaults,
            probePaths: ["/stale/claude"],
            versionOutput: { _ in "1.0.113 (Claude Code)" },
            loginShellLookup: { nil },
            fileExists: { _ in true })
        #expect(locator.probe() == nil)
        #expect(defaults.string(forKey: ClaudeBinaryLocator.pathDefaultsKey) == nil)
    }

    @Test func cachedEntryInvalidatedWhenBinaryDisappears() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("/gone/claude", forKey: ClaudeBinaryLocator.pathDefaultsKey)
        defaults.set("2.1.200", forKey: ClaudeBinaryLocator.versionDefaultsKey)
        let locator = ClaudeBinaryLocator(
            defaults: defaults, probePaths: [],
            versionOutput: { _ in nil }, loginShellLookup: { nil }, fileExists: { _ in false })
        #expect(locator.cached() == nil)
        #expect(locator.locate() == nil)
    }
}

// MARK: - Recent directories MRU

@Suite struct RecentDirectoriesTests {
    private func makeStore() throws -> (RecentDirectories, cleanup: () -> Void) {
        let suite = "voxi-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (RecentDirectories(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func newestFirstAndDeduplicated() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.noteUse(of: "/a")
        store.noteUse(of: "/b")
        store.noteUse(of: "/a")   // moves to front, no duplicate
        #expect(store.entries == ["/a", "/b"])
    }

    @Test func cappedAtTenEntries() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        for i in 0..<15 { store.noteUse(of: "/dir\(i)") }
        #expect(store.entries.count == 10)
        #expect(store.entries.first == "/dir14")
        #expect(store.entries.last == "/dir5")
    }

    @Test func removeDeletesEntry() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.noteUse(of: "/a")
        store.noteUse(of: "/b")
        store.remove("/a")
        #expect(store.entries == ["/b"])
    }

    @Test func emptyByDefault() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(store.entries.isEmpty)
    }
}

// MARK: - Registry

@Suite struct DispatcherRegistryTests {
    @Test func v1RegistersExactlyClaudeCode() {
        let registry = DispatcherRegistry.v1()
        #expect(registry.all.count == 1)
        #expect(registry.dispatcher(id: "claude-code") != nil)
        #expect(registry.dispatcher(id: "claude-code")?.displayName == "Claude Code")
        #expect(registry.dispatcher(id: "shell") == nil)
    }
}

@Suite struct ClaudeArgumentBuilderTests {
    @Test func defaultArgumentsMatchBaseline() throws {
        let args = try ClaudeCodeDispatcher.arguments(prompt: "Do it.", params: [:])
        #expect(args == [
            "-p", "Do it.",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "acceptEdits",
            "--max-turns", "25",
        ])
    }

    @Test func resumeSessionAppendsResumeFlag() throws {
        let args = try ClaudeCodeDispatcher.arguments(
            prompt: "P", params: ["resumeSessionID": " abc-123 "])
        let idx = try #require(args.firstIndex(of: "--resume"))
        #expect(args[idx + 1] == "abc-123")
    }

    @Test func blankResumeSessionIsIgnored() throws {
        let args = try ClaudeCodeDispatcher.arguments(
            prompt: "P", params: ["resumeSessionID": "   "])
        #expect(!args.contains("--resume"))
    }

    @Test func extraFlagsAppendAfterBuiltins() throws {
        let args = try ClaudeCodeDispatcher.arguments(
            prompt: "P", params: ["extraFlags": "--model sonnet"])
        #expect(Array(args.suffix(2)) == ["--model", "sonnet"])
    }
}

@Suite struct ClaudeRunSettingsTests {
    @Test func overridesReplaceTheDefaults() throws {
        let args = try ClaudeCodeDispatcher.arguments(
            prompt: "P", params: ["permissionMode": "plan", "maxTurns": "5"])
        let modeIdx = try #require(args.firstIndex(of: "--permission-mode"))
        #expect(args[modeIdx + 1] == "plan")
        let turnsIdx = try #require(args.firstIndex(of: "--max-turns"))
        #expect(args[turnsIdx + 1] == "5")
    }

    @Test func absentOrBlankSettingsFallBackToDefaults() throws {
        for params in [[String: String](), ["permissionMode": "", "maxTurns": "  "]] {
            let args = try ClaudeCodeDispatcher.arguments(prompt: "P", params: params)
            let modeIdx = try #require(args.firstIndex(of: "--permission-mode"))
            #expect(args[modeIdx + 1] == "acceptEdits")
            let turnsIdx = try #require(args.firstIndex(of: "--max-turns"))
            #expect(args[turnsIdx + 1] == "25")
        }
    }

    @Test func unknownPermissionModeFailsLoud() {
        #expect(throws: DispatcherError.self) {
            _ = try ClaudeCodeDispatcher.arguments(prompt: "P", params: ["permissionMode": "yolo"])
        }
    }

    @Test func badMaxTurnsFailsLoud() {
        for bad in ["abc", "0", "9999", "-3"] {
            #expect(throws: DispatcherError.self) {
                _ = try ClaudeCodeDispatcher.arguments(prompt: "P", params: ["maxTurns": bad])
            }
        }
    }
}
