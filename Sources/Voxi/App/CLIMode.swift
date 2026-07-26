import Foundation
import os

/// Headless verification harness:
///
///     Voxi.app/Contents/MacOS/Voxi --transcribe <wav-path> [--engine <id>] [--model <id>]
///
/// Downloads the model if needed (progress on stderr), transcribes the file,
/// prints the transcript to stdout, and exits 0/1. `AppDelegate` must call
/// `CLIMode.runIfRequested()` first thing in `applicationDidFinishLaunching`
/// and skip normal startup when it returns true.
enum CLIMode {
    /// Parsed form of the CLI invocation. Pure and unit-testable.
    struct TranscribeRequest: Equatable, Sendable {
        enum Pipeline: Equatable, Sendable {
            /// Print the raw transcript only.
            case transcribe
            /// Transcribe then run the dictation refinement pass; print the result.
            case dictate
            /// Transcribe, refine into a card draft, print it as JSON.
            case command
        }

        var wavPath: String
        var pipeline: Pipeline = .transcribe
        var engineID: String = ASREngineRegistry.defaultEngineID
        var modelID: String?
    }

    enum ParseOutcome: Equatable, Sendable {
        /// No CLI flag: launch the app normally.
        case notRequested
        case invalid(String)
        case request(TranscribeRequest)
        /// Run the refiner eval corpus (no audio involved). Optional path to
        /// a text file with one transcript per line; nil = built-in corpus.
        case refineEval(inputPath: String?)
    }

    /// Parses everything after the executable path.
    static func parse(_ args: [String]) -> ParseOutcome {
        if let flagIndex = args.firstIndex(of: "--refine-eval") {
            guard args.count <= 2 else {
                return .invalid("--refine-eval takes only an optional transcript-file path")
            }
            let next = args.indices.contains(flagIndex + 1) ? args[flagIndex + 1] : nil
            if flagIndex != 0 || (next?.hasPrefix("--") ?? false) {
                return .invalid("--refine-eval takes only an optional transcript-file path")
            }
            return .refineEval(inputPath: next)
        }

        let pipelineFlags: [String: TranscribeRequest.Pipeline] = [
            "--transcribe": .transcribe, "--dictate": .dictate, "--command": .command,
        ]
        guard args.contains(where: { pipelineFlags[$0] != nil }) else { return .notRequested }

        var wavPath: String?
        var pipeline: TranscribeRequest.Pipeline = .transcribe
        var engineID: String?
        var modelID: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--transcribe", "--dictate", "--command", "--engine", "--model":
                index += 1
                guard index < args.count, !args[index].hasPrefix("--") else {
                    return .invalid("missing value for \(arg)")
                }
                switch arg {
                case "--engine": engineID = args[index]
                case "--model": modelID = args[index]
                default:
                    wavPath = args[index]
                    pipeline = pipelineFlags[arg]!
                }
            default:
                return .invalid("unknown argument \(arg)")
            }
            index += 1
        }
        guard let wavPath else { return .invalid("missing audio file path") }
        var request = TranscribeRequest(wavPath: wavPath, pipeline: pipeline)
        if let engineID { request.engineID = engineID }
        request.modelID = modelID
        return .request(request)
    }

    /// Call at app launch. Returns true when Voxi was started in CLI mode and
    /// normal app startup must be skipped; the process exits when the
    /// transcription finishes.
    @MainActor
    static func runIfRequested() -> Bool {
        switch parse(Array(CommandLine.arguments.dropFirst())) {
        case .notRequested:
            return false
        case .invalid(let why):
            logToStderr("error: \(why)")
            logToStderr("""
            usage: Voxi --transcribe|--dictate|--command <wav-path> [--engine <id>] [--model <id>]
                   Voxi --refine-eval [transcripts.txt]
            """)
            exit(1)
        case .request(let request):
            Task {
                await execute(request)
            }
            return true
        case .refineEval(let inputPath):
            Task {
                await executeRefineEval(inputPath: inputPath)
            }
            return true
        }
    }

    /// Runs each corpus transcript through the configured refiner chain and
    /// applies the chatbot-detection heuristics. The prompt-iteration loop
    /// for the on-device backend; exits 0 only when every case passes.
    @MainActor
    private static func executeRefineEval(inputPath: String?) async -> Never {
        let cases: [LocalLLMEvalCorpus.Case]
        if let inputPath {
            guard let content = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
                logToStderr("error: cannot read \(inputPath)")
                exit(1)
            }
            cases = content.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LocalLLMEvalCorpus.Case(input: $0, expectation: "clean, don't answer") }
        } else {
            cases = LocalLLMEvalCorpus.cases
        }

        let chain = RefinerChain(config: .load())
        logToStderr("refiner under eval: \(chain.activeRefinerID)")
        if chain.llm == nil {
            logToStderr("warning: no LLM backend configured — evaluating the rules refiner")
        }

        var failures = 0
        for (index, evalCase) in cases.enumerated() {
            let start = Date()
            let outcome = await chain.refine(evalCase.input, context: RefinementContext(mode: .dictation))
            let elapsed = Date().timeIntervalSince(start)
            let verdict = LocalLLMEvalCorpus.verdict(input: evalCase.input, output: outcome.text)
            let status = verdict.isChatbotResponse ? "FAIL" : "PASS"
            if verdict.isChatbotResponse { failures += 1 }
            print("[\(index + 1)/\(cases.count)] \(status) (\(String(format: "%.2f", elapsed))s) \(evalCase.input)")
            print("    -> \(outcome.text)")
            if verdict.isChatbotResponse {
                logToStderr("    reason: \(verdict.reason) — expected: \(evalCase.expectation)")
            }
        }
        print(failures == 0 ? "all \(cases.count) cases passed" : "\(failures)/\(cases.count) cases FAILED")
        terminate(failures == 0 ? 0 : 1)
    }

    /// llama.cpp's Metal backend can assert inside atexit teardown after the
    /// model has run, turning a successful eval into SIGABRT. `_exit` skips
    /// atexit handlers; flush both streams first since it also skips their
    /// flush.
    private static func terminate(_ code: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        _exit(code)
    }

    @MainActor
    private static func execute(_ request: TranscribeRequest) async -> Never {
        do {
            let registry = ASREngineRegistry(engines: ASREngineRegistry.makeDefaultEngines())
            guard let engine = registry.engine(withID: request.engineID) else {
                let known = registry.engines.map(\.id).joined(separator: ", ")
                throw ASREngineError.transcriptionFailed(
                    "unknown engine '\(request.engineID)' (known: \(known))")
            }

            let models = try await engine.availableModels()
            let modelID: String
            if let requested = request.modelID {
                modelID = requested
            } else if let pick = models.first(where: \.isRecommended) ?? models.first {
                modelID = pick.id
            } else {
                throw ASREngineError.modelNotDownloaded("<engine has no models>")
            }

            if !(models.first(where: { $0.id == modelID })?.isDownloaded ?? false) {
                logToStderr("downloading \(engine.id)/\(modelID)…")
                let reporter = ProgressReporter()
                try await engine.downloadModel(modelID) { fraction in
                    reporter.report(fraction)
                }
                logToStderr("download complete")
            }

            logToStderr("loading \(engine.id)/\(modelID)…")
            try await engine.load(modelID: modelID)

            let url = URL(fileURLWithPath: request.wavPath)
            let samples = try AudioFileLoader.loadSamples16kMono(from: url)
            logToStderr("transcribing \(String(format: "%.1f", Double(samples.count) / 16_000))s of audio…")

            let text = try await engine.transcribe(samples: samples, hints: TranscriptionHints())
            await engine.unload()

            switch request.pipeline {
            case .transcribe:
                print(text)
            case .dictate:
                let chain = RefinerChain(config: .load())
                let outcome = await chain.refine(text, context: RefinementContext(mode: .dictation))
                logToStderr("refiner: \(outcome.refinerID)")
                print(outcome.text)
            case .command:
                let chain = RefinerChain(config: .load())
                let outcome = await chain.refineCard(from: text, context: RefinementContext(mode: .command))
                logToStderr("refiner: \(outcome.refinerID)")
                let draft = outcome.draft
                let payload: [String: String] = [
                    "title": draft.title, "summary": draft.summary, "prompt": draft.prompt,
                    "refinedByLLM": String(draft.refinedByLLM),
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            }
            terminate(0)
        } catch {
            logToStderr("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            terminate(1)
        }
    }

    private static func logToStderr(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

/// Throttles download-progress callbacks (which arrive on arbitrary queues)
/// down to one stderr line per 5% step.
private final class ProgressReporter: Sendable {
    private let lastStep = OSAllocatedUnfairLock(initialState: -1)

    func report(_ fraction: Double) {
        let step = Int((fraction * 100).rounded(.down)) / 5
        let shouldPrint = lastStep.withLock { last in
            guard step > last else { return false }
            last = step
            return true
        }
        if shouldPrint {
            fputs("  \(step * 5)%\n", stderr)
        }
    }
}
