import Testing
@testable import Voxi

@Suite struct TranscriptionCLIModeTests {
    @Test func normalLaunchIsNotRequested() {
        #expect(CLIMode.parse([]) == .notRequested)
        #expect(CLIMode.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == .notRequested)
    }

    @Test func minimalInvocation() {
        let outcome = CLIMode.parse(["--transcribe", "/tmp/a.wav"])
        #expect(outcome == .request(CLIMode.TranscribeRequest(wavPath: "/tmp/a.wav")))
        // Default engine is parakeet.
        if case .request(let request) = outcome {
            #expect(request.engineID == "parakeet")
            #expect(request.modelID == nil)
        }
    }

    @Test func engineAndModelFlags() {
        let outcome = CLIMode.parse([
            "--transcribe", "/tmp/a.wav", "--engine", "whisperkit", "--model", "openai_whisper-tiny",
        ])
        #expect(outcome == .request(CLIMode.TranscribeRequest(
            wavPath: "/tmp/a.wav", engineID: "whisperkit", modelID: "openai_whisper-tiny")))
    }

    @Test func flagOrderDoesNotMatter() {
        let outcome = CLIMode.parse(["--engine", "whisperkit", "--transcribe", "/tmp/a.wav"])
        #expect(outcome == .request(CLIMode.TranscribeRequest(
            wavPath: "/tmp/a.wav", engineID: "whisperkit")))
    }

    @Test func missingValuesAreInvalid() {
        #expect(CLIMode.parse(["--transcribe"]) == .invalid("missing value for --transcribe"))
        #expect(CLIMode.parse(["--transcribe", "--engine", "parakeet"])
            == .invalid("missing value for --transcribe"))
        #expect(CLIMode.parse(["--transcribe", "/tmp/a.wav", "--model"])
            == .invalid("missing value for --model"))
    }

    @Test func unknownArgumentIsInvalid() {
        #expect(CLIMode.parse(["--transcribe", "/tmp/a.wav", "--frobnicate"])
            == .invalid("unknown argument --frobnicate"))
    }
}
