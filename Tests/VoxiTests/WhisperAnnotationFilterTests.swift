import Testing
@testable import Voxi

@Suite struct WhisperAnnotationFilterTests {
    @Test func stripsBlankAudio() {
        #expect(WhisperAnnotationFilter.strip("[BLANK_AUDIO]") == "")
        #expect(WhisperAnnotationFilter.strip("[ BLANK AUDIO ]") == "")
        #expect(WhisperAnnotationFilter.strip("(blank audio)") == "")
    }

    @Test func stripsOtherNonSpeechMarkers() {
        #expect(WhisperAnnotationFilter.strip("(music)") == "")
        #expect(WhisperAnnotationFilter.strip("[inaudible]") == "")
        #expect(WhisperAnnotationFilter.strip("[APPLAUSE]") == "")
    }

    @Test func stripsAnnotationEmbeddedInSpeech() {
        #expect(WhisperAnnotationFilter.strip("Hello [BLANK_AUDIO] world") == "Hello world")
        #expect(WhisperAnnotationFilter.strip("Send the report. (music)") == "Send the report.")
    }

    @Test func leavesRealSpeechAlone() {
        #expect(WhisperAnnotationFilter.strip("The music was great.") == "The music was great.")
        #expect(WhisperAnnotationFilter.strip("Set flags to [1, 2, 3].") == "Set flags to [1, 2, 3].")
        #expect(WhisperAnnotationFilter.strip("Call me (maybe).") == "Call me (maybe).")
    }
}
