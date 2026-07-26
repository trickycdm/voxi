import Foundation
import Testing
@testable import Voxi

@Suite struct CorrectionInferenceTests {
    private func infer(
        _ baseline: String, _ observed: String, inserted: String? = nil
    ) -> CorrectionInference.Correction? {
        CorrectionInference.inferredCorrection(
            from: baseline, to: observed, constrainedTo: inserted ?? baseline)
    }

    @Test func learnsSingleWordFix() {
        let correction = infer(
            "send the invoice to Jordn tomorrow",
            "send the invoice to Jordan tomorrow")
        #expect(correction == .init(wrong: "Jordn", right: "Jordan"))
    }

    @Test func learnsTwoWordFix() {
        let correction = infer(
            "ping the whisper kit maintainers",
            "ping the WhisperKit maintainers")
        #expect(correction == .init(wrong: "whisper kit", right: "WhisperKit"))
    }

    @Test func rejectsLongerSpans() {
        #expect(infer(
            "one two three four five six",
            "uno dos tres cuatro five six") == nil)
    }

    @Test func rejectsPunctuationOnlyChange() {
        #expect(infer(
            "send it to Jordan tomorrow",
            "send it to Jordan, tomorrow") == nil)
    }

    @Test func rejectsCaseOnlyChange() {
        #expect(infer(
            "meet jordan at noon",
            "meet Jordan at noon") == nil)
    }

    @Test func rejectsWhenWrongNotInInsertedText() {
        // The changed word was typed by the user later, not inserted by us.
        #expect(infer(
            "the quick brown fox",
            "the quick red fox",
            inserted: "a completely different dictation") == nil)
    }

    @Test func rejectsWholesaleRewrite() {
        #expect(infer(
            "please review the parser changes",
            "totally unrelated sentence now") == nil)
    }

    @Test func rejectsIdenticalTexts() {
        #expect(infer("same text here", "same text here") == nil)
        #expect(infer("Same Text Here", "same text here") == nil)
    }

    @Test func trimsSurroundingPunctuation() {
        // The fix touches the last word; its period must not enter the pair.
        let correction = infer(
            "send the report to Jordn.",
            "send the report to Jordan.")
        #expect(correction == .init(wrong: "Jordn", right: "Jordan"))
    }

    @Test func matchesWrongInInsertedTextDespitePunctuation() {
        let correction = infer(
            "the fix is in Voxy, ship it",
            "the fix is in Voxi, ship it",
            inserted: "the fix is in Voxy, ship it")
        #expect(correction == .init(wrong: "Voxy", right: "Voxi"))
    }
}

@MainActor
@Suite struct PostInsertObserverTests {
    /// Drives the observer with a scripted sequence of field readings; the
    /// injected sleeper advances instantly.
    private final class Script {
        var fieldReadings: [String?]
        var frontmost: String?
        var learned: [CorrectionInference.Correction] = []
        private var index = 0

        init(fieldReadings: [String?], frontmost: String?) {
            self.fieldReadings = fieldReadings
            self.frontmost = frontmost
        }

        func nextReading() -> String? {
            defer { index += 1 }
            return index < fieldReadings.count ? fieldReadings[index] : fieldReadings.last ?? nil
        }
    }

    private func makeObserver(_ script: Script) -> PostInsertObserver {
        let observer = PostInsertObserver(
            readField: { script.nextReading() },
            readFrontmost: { script.frontmost },
            sleeper: { _ in await Task.yield() }
        )
        observer.onLearnedCorrection = { script.learned.append($0) }
        return observer
    }

    private func waitForCompletion() async {
        // The observer's task runs at most maximumPollCount instant polls.
        for _ in 0..<(PostInsertObserver.maximumPollCount * 4) { await Task.yield() }
    }

    @Test func learnsAfterQuiescence() async {
        let inserted = "send it to Jordn now"
        let edited = "send it to Jordan now"
        // Baseline read + polls: user edits, then the field stays stable.
        let script = Script(
            fieldReadings: [inserted, inserted, edited, edited, edited, edited],
            frontmost: "com.example.app")
        let observer = makeObserver(script)
        observer.begin(insertedText: inserted, targetBundleID: "com.example.app")
        await waitForCompletion()
        #expect(script.learned == [.init(wrong: "Jordn", right: "Jordan")])
    }

    @Test func abortsWhenFrontmostAppChanges() async {
        let inserted = "send it to Jordn now"
        let script = Script(
            fieldReadings: [inserted, "send it to Jordan now"],
            frontmost: "com.example.app")
        let observer = makeObserver(script)
        observer.begin(insertedText: inserted, targetBundleID: "com.other.app")
        await waitForCompletion()
        #expect(script.learned.isEmpty)
    }

    @Test func learnsNothingFromWholesaleRewrite() async {
        let inserted = "please review the parser changes"
        let script = Script(
            fieldReadings: [inserted, "totally different text now", "totally different text now",
                            "totally different text now"],
            frontmost: "com.example.app")
        let observer = makeObserver(script)
        observer.begin(insertedText: inserted, targetBundleID: "com.example.app")
        await waitForCompletion()
        #expect(script.learned.isEmpty)
    }

    @Test func newSessionCancelsPreviousObservation() async {
        let script = Script(
            fieldReadings: ["send it to Jordn", "send it to Jordan"],
            frontmost: "com.example.app")
        let observer = makeObserver(script)
        observer.begin(insertedText: "send it to Jordn", targetBundleID: "com.example.app")
        observer.begin(insertedText: "unrelated new dictation", targetBundleID: "com.example.app")
        await waitForCompletion()
        // The first observation was cancelled; the second can't derive the
        // Jordn→Jordan pair because "Jordn" isn't in its inserted text.
        #expect(script.learned.isEmpty)
    }

    @Test func nilTargetBundleNeverObserves() async {
        let script = Script(fieldReadings: ["a", "b"], frontmost: nil)
        let observer = makeObserver(script)
        observer.begin(insertedText: "a", targetBundleID: nil)
        await waitForCompletion()
        #expect(script.learned.isEmpty)
    }
}

@Suite struct InsertionSettingsDecodeTests {
    @Test func legacySettingsJSONDecodesWithLearnDefault() throws {
        let legacy = Data("""
        {"method":"pasteboardAlways","restoreClipboard":false,
         "markConcealed":true,"restoreDelayMilliseconds":500}
        """.utf8)
        let settings = try JSONDecoder().decode(InsertionSettings.self, from: legacy)
        #expect(settings.method == .pasteboardAlways)
        #expect(settings.restoreClipboard == false)
        #expect(settings.markConcealed == true)
        #expect(settings.restoreDelayMilliseconds == 500)
        #expect(settings.learnCorrections == true)
    }

    @Test func roundTripsLearnCorrections() throws {
        var settings = InsertionSettings()
        settings.learnCorrections = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InsertionSettings.self, from: data)
        #expect(decoded.learnCorrections == false)
    }
}
