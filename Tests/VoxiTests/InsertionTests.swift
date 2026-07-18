import AppKit
import Testing
@testable import Voxi

@Suite struct SmartFormatterTests {
    let formatter = SmartFormatter()

    private func surroundings(before: Character? = nil, unreadable: Bool = false) -> InsertionSurroundings {
        InsertionSurroundings(charBeforeCaret: before, charAfterCaret: nil, unreadable: unreadable)
    }

    // MARK: Capitalization

    @Test func startOfFieldCapitalizes() {
        #expect(formatter.format("hello world", surroundings: surroundings()) == "Hello world")
    }

    @Test func emptyFieldTrimsAndCapitalizes() {
        #expect(formatter.format("  hello  ", surroundings: surroundings()) == "Hello")
    }

    @Test func afterNewlineCapitalizesWithoutSpace() {
        #expect(formatter.format("hello", surroundings: surroundings(before: "\n")) == "Hello")
    }

    @Test func afterTerminatorCapitalizesAndPrependsSpace() {
        #expect(formatter.format("it works", surroundings: surroundings(before: ".")) == " It works")
        #expect(formatter.format("really", surroundings: surroundings(before: "!")) == " Really")
        #expect(formatter.format("why not", surroundings: surroundings(before: "?")) == " Why not")
    }

    @Test func afterTerminatorPlusSpaceCapitalizesWithoutSpace() {
        #expect(formatter.format("it works", before: ". ", unreadable: false) == "It works")
        #expect(formatter.format("sure", before: "d! ", unreadable: false) == "Sure")
    }

    @Test func afterNewlinePlusSpacesCapitalizes() {
        #expect(formatter.format("bullet point", before: "\n  ", unreadable: false) == "Bullet point")
    }

    // MARK: Mid-sentence lowercasing

    @Test func midSentenceAfterLowercaseLowercasesAndPrependsSpace() {
        #expect(formatter.format("Hello there", surroundings: surroundings(before: "o")) == " hello there")
    }

    @Test func afterCommaLowercasesAndPrependsSpace() {
        #expect(formatter.format("Then we left", surroundings: surroundings(before: ",")) == " then we left")
    }

    @Test func afterLowercasePlusSpaceLowercasesWithoutSpace() {
        #expect(formatter.format("Next thing", before: "o ", unreadable: false) == "next thing")
    }

    @Test func acronymPreservedMidSentence() {
        #expect(formatter.format("NASA launched it", surroundings: surroundings(before: "e")) == " NASA launched it")
    }

    @Test func camelCasePreservedMidSentence() {
        #expect(formatter.format("McDonald was there", surroundings: surroundings(before: "e")) == " McDonald was there")
    }

    @Test func pronounIPreservedMidSentence() {
        #expect(formatter.format("I think so", surroundings: surroundings(before: "e")) == " I think so")
        #expect(formatter.format("I'm sure", surroundings: surroundings(before: "e")) == " I'm sure")
        #expect(formatter.format("I’ll go", surroundings: surroundings(before: "e")) == " I’ll go")
        #expect(formatter.format("I've seen it", surroundings: surroundings(before: ",")) == " I've seen it")
        #expect(formatter.format("I'd rather not", surroundings: surroundings(before: "e")) == " I'd rather not")
    }

    @Test func ordinaryWordWithTrailingPunctuationStillLowercases() {
        #expect(formatter.format("Yes, indeed", surroundings: surroundings(before: "o")) == " yes, indeed")
    }

    // MARK: Spacing

    @Test func afterDigitPrependsSpaceKeepsCasing() {
        #expect(formatter.format("items remain", surroundings: surroundings(before: "2")) == " items remain")
    }

    @Test func afterClosingPunctuationPrependsSpace() {
        #expect(formatter.format("and more", surroundings: surroundings(before: ")")) == " and more")
        #expect(formatter.format("he said", surroundings: surroundings(before: "\"")) == " he said")
    }

    @Test func afterUppercaseKeepsCasingPrependsSpace() {
        // Ambiguous context (could be an acronym mid-way): don't touch casing.
        #expect(formatter.format("something", surroundings: surroundings(before: "A")) == " something")
    }

    @Test func afterSpaceNoExtraSpace() {
        #expect(formatter.format("more words", before: "o ", unreadable: false) == "more words")
    }

    // MARK: Neutral / degenerate

    @Test func unreadableIsNeutralExceptTrimming() {
        #expect(formatter.format("  Hello world  ", surroundings: surroundings(unreadable: true)) == "Hello world")
        #expect(formatter.format("already lowercase", surroundings: surroundings(unreadable: true)) == "already lowercase")
    }

    @Test func whitespaceOnlyTranscriptBecomesEmpty() {
        #expect(formatter.format("   \n ", surroundings: surroundings()) == "")
        #expect(formatter.format("", surroundings: surroundings(before: ".")) == "")
    }

    @Test func protocolAndWindowVariantsAgreeOnSingleChar() {
        let viaProtocol = formatter.format("hello", surroundings: surroundings(before: "."))
        let viaWindow = formatter.format("hello", before: ".", unreadable: false)
        #expect(viaProtocol == viaWindow)
    }
}

@MainActor
@Suite struct PasteboardRoundTripTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.colin.voxi.tests.\(UUID().uuidString)"))
    }

    @Test func snapshotRestoreRoundTrip() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.colin.voxi.test-type")
        pb.clearContents()
        pb.setString("original text", forType: .string)
        pb.setData(Data([1, 2, 3]), forType: customType)

        let snap = PasteboardInserter.snapshot(of: pb)
        let changeCount = PasteboardInserter.writeTranscript("dictated words", to: pb, concealed: false)
        #expect(pb.string(forType: .string) == "dictated words")
        #expect(pb.data(forType: .voxiTransient) != nil)
        #expect(pb.string(forType: .voxiSource) != nil)

        let restored = PasteboardInserter.restoreIfUnchanged(snap, to: pb, expectedChangeCount: changeCount)
        #expect(restored)
        #expect(pb.string(forType: .string) == "original text")
        #expect(pb.data(forType: customType) == Data([1, 2, 3]))
        #expect(pb.data(forType: .voxiTransient) == nil)
    }

    @Test func changeCountGuardPreventsClobber() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)

        let snap = PasteboardInserter.snapshot(of: pb)
        let changeCount = PasteboardInserter.writeTranscript("dictated", to: pb, concealed: false)

        // The user copies something between our write and the restore window.
        pb.clearContents()
        pb.setString("user copied this", forType: .string)

        let restored = PasteboardInserter.restoreIfUnchanged(snap, to: pb, expectedChangeCount: changeCount)
        #expect(!restored)
        #expect(pb.string(forType: .string) == "user copied this")
    }

    @Test func concealedMarkerIsOptIn() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        _ = PasteboardInserter.writeTranscript("secret", to: pb, concealed: true)
        #expect(pb.data(forType: .voxiConcealed) != nil)

        _ = PasteboardInserter.writeTranscript("plain", to: pb, concealed: false)
        #expect(pb.data(forType: .voxiConcealed) == nil)
    }

    @Test func emptyPasteboardRoundTrip() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()

        let snap = PasteboardInserter.snapshot(of: pb)
        let changeCount = PasteboardInserter.writeTranscript("words", to: pb, concealed: false)
        #expect(PasteboardInserter.restoreIfUnchanged(snap, to: pb, expectedChangeCount: changeCount))
        #expect(pb.string(forType: .string) == nil)
    }
}

@Suite struct InsertionSettingsTests {
    @Test func codableRoundTrip() throws {
        var settings = InsertionSettings()
        settings.method = .appleScript
        settings.restoreClipboard = false
        settings.markConcealed = true
        settings.restoreDelayMilliseconds = 450

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InsertionSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func loadReturnsDefaultsWhenAbsent() {
        let defaults = UserDefaults(suiteName: "com.colin.voxi.tests.\(UUID().uuidString)")!
        #expect(InsertionSettings.load(from: defaults) == InsertionSettings())
    }

    @Test func saveThenLoad() {
        let suite = "com.colin.voxi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = InsertionSettings()
        settings.method = .pasteboardAlways
        settings.save(to: defaults)
        #expect(InsertionSettings.load(from: defaults) == settings)
    }
}

@Suite struct ElectronDetectionTests {
    @Test func detectsElectronFrameworkBundle() throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("FakeApp-\(UUID()).app")
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }

        #expect(AXFocus.isElectronApp(bundleURL: bundle))
        #expect(!AXFocus.isElectronApp(bundleURL: fm.temporaryDirectory))
        #expect(!AXFocus.isElectronApp(bundleURL: nil))
    }
}

@Suite struct SecureInputVerdictTests {
    private let mdmAgent = SecureInput.Holder(pid: 390, bundleID: nil, name: nil)
    private let safari = SecureInput.Holder(
        pid: 812, bundleID: "com.apple.Safari", name: "Safari")

    @Test func disabledFlagAllows() {
        #expect(SecureInput.verdict(
            secureInputEnabled: false, holders: [], targetPID: 100, targetBundleID: "com.a.b"
        ) == .allow)
    }

    @Test func backgroundHolderDoesNotBlockOtherApps() {
        // The work-Mac case: an MDM daemon holds secure input session-long.
        #expect(SecureInput.verdict(
            secureInputEnabled: true, holders: [mdmAgent],
            targetPID: 100, targetBundleID: "com.apple.TextEdit"
        ) == .allow)
    }

    @Test func targetHoldingByPIDBlocksAndNamesHolder() {
        #expect(SecureInput.verdict(
            secureInputEnabled: true, holders: [safari],
            targetPID: 812, targetBundleID: "com.apple.Safari"
        ) == .heldByTarget(holderName: "Safari"))
    }

    @Test func targetHoldingViaHelperProcessMatchesByBundle() {
        // Browsers take the hold from a helper PID, not the frontmost app PID.
        let helper = SecureInput.Holder(
            pid: 999, bundleID: "com.apple.Safari", name: "Safari")
        #expect(SecureInput.verdict(
            secureInputEnabled: true, holders: [mdmAgent, helper],
            targetPID: 812, targetBundleID: "com.apple.Safari"
        ) == .heldByTarget(holderName: "Safari"))
    }

    @Test func nilBundleHolderNeverMatchesNilBundleTarget() {
        // A daemon holder (bundleID nil) must not bundle-match a target that
        // also reports no bundle ID.
        #expect(SecureInput.verdict(
            secureInputEnabled: true, holders: [mdmAgent],
            targetPID: 100, targetBundleID: nil
        ) == .allow)
    }

    @Test func unknownHolderRefuses() {
        #expect(SecureInput.verdict(
            secureInputEnabled: true, holders: [], targetPID: 100, targetBundleID: "com.a.b"
        ) == .heldByUnknown)
    }
}
