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
        var wavPath: String
        var engineID: String = ASREngineRegistry.defaultEngineID
        var modelID: String?
    }

    enum ParseOutcome: Equatable, Sendable {
        /// No `--transcribe` flag: launch the app normally.
        case notRequested
        case invalid(String)
        case request(TranscribeRequest)
    }

    /// Parses everything after the executable path.
    static func parse(_ args: [String]) -> ParseOutcome {
        guard args.contains("--transcribe") else { return .notRequested }

        var wavPath: String?
        var engineID: String?
        var modelID: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--transcribe", "--engine", "--model":
                index += 1
                guard index < args.count, !args[index].hasPrefix("--") else {
                    return .invalid("missing value for \(arg)")
                }
                switch arg {
                case "--transcribe": wavPath = args[index]
                case "--engine": engineID = args[index]
                default: modelID = args[index]
                }
            default:
                return .invalid("unknown argument \(arg)")
            }
            index += 1
        }
        guard let wavPath else { return .invalid("missing value for --transcribe") }
        var request = TranscribeRequest(wavPath: wavPath)
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
            logToStderr("usage: Voxi --transcribe <wav-path> [--engine <id>] [--model <id>]")
            exit(1)
        case .request(let request):
            Task {
                await execute(request)
            }
            return true
        }
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

            print(text)
            exit(0)
        } catch {
            logToStderr("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            exit(1)
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
