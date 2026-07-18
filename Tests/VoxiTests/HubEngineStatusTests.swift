import Testing
@testable import Voxi

@Suite struct HubEngineStatusTests {
    // MARK: shortName

    @Test func shortNameTruncatesParentheticalSuffix() {
        #expect(EngineStatusLine.shortName(from: "Parakeet (FluidAudio)") == "Parakeet")
        #expect(EngineStatusLine.shortName(from: "Whisper (WhisperKit)") == "Whisper")
    }

    @Test func shortNamePassesThroughPlainNames() {
        #expect(EngineStatusLine.shortName(from: "Parakeet") == "Parakeet")
    }

    @Test func shortNameSurvivesHostileInputs() {
        #expect(EngineStatusLine.shortName(from: "") == "")
        #expect(EngineStatusLine.shortName(from: " (weird") == " (weird")
        #expect(EngineStatusLine.shortName(from: "Name (") == "Name")
    }

    // MARK: make

    @Test func readyWhenLoadedMatchesSelected() {
        let line = EngineStatusLine.make(
            engineDisplayName: "Parakeet (FluidAudio)",
            selectedEngineID: "parakeet",
            loadedEngineID: "parakeet")
        #expect(line == EngineStatusLine(text: "Parakeet · ready", isReady: true))
    }

    @Test func standbyWhenNothingLoaded() {
        let line = EngineStatusLine.make(
            engineDisplayName: "Parakeet (FluidAudio)",
            selectedEngineID: "parakeet",
            loadedEngineID: nil)
        #expect(line == EngineStatusLine(text: "Parakeet · standby", isReady: false))
    }

    @Test func standbyWhenStaleEngineLoaded() {
        let line = EngineStatusLine.make(
            engineDisplayName: "Whisper (WhisperKit)",
            selectedEngineID: "whisperkit",
            loadedEngineID: "parakeet")
        #expect(line == EngineStatusLine(text: "Whisper · standby", isReady: false))
    }
}
