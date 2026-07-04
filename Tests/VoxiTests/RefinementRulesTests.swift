import Testing
@testable import Voxi

@Suite struct RefinementFillerTests {
    @Test func removesStandaloneUm() {
        #expect(RefinementRules.clean("Um, send the email") == "Send the email.")
    }

    @Test func removesUhMidSentence() {
        #expect(RefinementRules.clean("Send the email to, uh, John") == "Send the email to John.")
    }

    @Test func removesErm() {
        #expect(RefinementRules.clean("erm let me think about it") == "Let me think about it.")
    }

    @Test func summerKeepsItsUm() {
        #expect(RefinementRules.clean("plan the summer trip") == "Plan the summer trip.")
    }

    @Test func umbrellaKeepsItsUm() {
        #expect(RefinementRules.clean("Um, grab the umbrella") == "Grab the umbrella.")
    }

    @Test func uhHuhIsNotSplit() {
        #expect(RefinementRules.removeFillers("she said uh-huh") == "she said uh-huh")
    }

    @Test func repeatedFillers() {
        #expect(RefinementRules.clean("um, um, send it now") == "Send it now.")
    }

    @Test func youKnowRemovedWhenPauseDelimited() {
        #expect(RefinementRules.clean("You know, this is great") == "This is great.")
        #expect(RefinementRules.clean("It was, you know, fine") == "It was, fine.")
    }

    @Test func youKnowKeptInsideRealSentence() {
        #expect(RefinementRules.clean("do you know John") == "Do you know John.")
        #expect(RefinementRules.clean("let me know when you know the answer")
            == "Let me know when you know the answer.")
    }
}

@Suite struct RefinementCorrectionTests {
    @Test func fixtureSentence() {
        let input = "Send the report to John. Actually, scratch that. Send the report to Sarah instead."
        #expect(RefinementRules.clean(input) == "Send the report to Sarah instead.")
    }

    @Test func correctionAtStart() {
        #expect(RefinementRules.clean("No wait, send it to Sarah") == "Send it to Sarah.")
    }

    @Test func inlineCorrectionMidSentence() {
        #expect(RefinementRules.clean("Send it to John, no wait, send it to Sarah")
            == "Send it to Sarah.")
    }

    @Test func correctionAtEndCancelsPreviousSentence() {
        // "scratch that" with no continuation cancels what came before.
        #expect(RefinementRules.clean("Send the report to John. Scratch that.") == "")
    }

    @Test func multipleCorrectionsKeepLast() {
        let input = "Email Bob. No wait. Email Alice. Scratch that. Email Carol."
        #expect(RefinementRules.clean(input) == "Email Carol.")
    }

    @Test func scratchThatSayKeepsOnlyContinuation() {
        #expect(RefinementRules.clean("scratch that, say email Bob about the launch")
            == "Email Bob about the launch.")
    }

    @Test func waitNoVariant() {
        #expect(RefinementRules.clean("Order pizza. Wait, no. Order sushi.") == "Order sushi.")
    }

    @Test func noWaitingIsNotACorrection() {
        #expect(RefinementRules.clean("there is no waiting list") == "There is no waiting list.")
    }

    @Test func plainTextUnchangedByCorrections() {
        #expect(RefinementRules.applyCorrections("Send the report to Sarah.")
            == "Send the report to Sarah.")
    }
}

@Suite struct RefinementCapitalizationTests {
    @Test func sentenceStartsCapitalized() {
        #expect(RefinementRules.clean("hello there. how are you") == "Hello there. How are you.")
    }

    @Test func standaloneIAndContractions() {
        #expect(RefinementRules.clean("i think i'm ready and i'll go") == "I think I'm ready and I'll go.")
    }

    @Test func iInsideWordsUntouched() {
        #expect(RefinementRules.clean("it is idiomatic") == "It is idiomatic.")
    }

    @Test func dottedNamesDoNotStartSentences() {
        #expect(RefinementRules.clean("build it with next.js please") == "Build it with next.js please.")
    }

    @Test func digitSentenceStartLeavesNextWordAlone() {
        #expect(RefinementRules.capitalize("done. 3 files remain here") == "Done. 3 files remain here")
    }
}

@Suite struct RefinementPunctuationTests {
    @Test func collapsesDuplicateSpaces() {
        #expect(RefinementRules.clean("send   the   report") == "Send the report.")
    }

    @Test func removesSpaceBeforePunctuation() {
        #expect(RefinementRules.clean("hello , world .") == "Hello, world.")
    }

    @Test func addsTerminalPunctuationForMultiWord() {
        #expect(RefinementRules.clean("send the report") == "Send the report.")
    }

    @Test func singleWordGetsNoTerminalPunctuation() {
        #expect(RefinementRules.clean("hello") == "Hello")
    }

    @Test func existingTerminalPunctuationKept() {
        #expect(RefinementRules.clean("is it ready?") == "Is it ready?")
        #expect(RefinementRules.clean("do it now!") == "Do it now!")
    }

    @Test func trailingCommaBecomesPeriod() {
        #expect(RefinementRules.clean("send the report,") == "Send the report.")
    }

    @Test func emptyAndWhitespaceTranscripts() {
        #expect(RefinementRules.clean("") == "")
        #expect(RefinementRules.clean("   \n\t ") == "")
    }
}

@Suite struct RefinementDictionaryTests {
    @Test func wrongCaseReplacedWithCanonical() {
        let terms = [DictionaryTerm(canonical: "Voxi")]
        #expect(RefinementRules.clean("i love voxi", dictionary: terms) == "I love Voxi.")
    }

    @Test func variantReplacedWithCanonical() {
        let terms = [DictionaryTerm(canonical: "GRDB", variants: ["gee are db", "gerdb"])]
        #expect(RefinementRules.clean("use gee are db for storage", dictionary: terms)
            == "Use GRDB for storage.")
        #expect(RefinementRules.clean("gerdb is fast", dictionary: terms) == "GRDB is fast.")
    }

    @Test func wordBoundarySafety() {
        let terms = [DictionaryTerm(canonical: "Cal")]
        #expect(RefinementRules.enforceDictionary("check my calendar", terms: terms)
            == "check my calendar")
        #expect(RefinementRules.enforceDictionary("ask cal about it", terms: terms)
            == "ask Cal about it")
    }

    @Test func multiWordCanonicalTerm() {
        let terms = [DictionaryTerm(canonical: "Claude Code", variants: ["cloud code"])]
        #expect(RefinementRules.clean("dispatch it to cloud code", dictionary: terms)
            == "Dispatch it to Claude Code.")
    }

    @Test func vocabularyFlowsThroughRefinerContext() async throws {
        let refiner = RuleBasedRefiner()
        let context = RefinementContext(mode: .dictation, vocabulary: ["WhisperKit"])
        let out = try await refiner.refine("use whisperkit for transcription", context: context)
        #expect(out == "Use WhisperKit for transcription.")
    }

    @Test func dictionaryProviderVariantsApply() async throws {
        let refiner = RuleBasedRefiner(dictionary: {
            [DictionaryTerm(canonical: "Wispr", variants: ["whisper flow"])]
        })
        let out = try await refiner.refine(
            "make it feel like whisper flow",
            context: RefinementContext()
        )
        #expect(out == "Make it feel like Wispr.")
    }
}

@Suite struct RefinementCardDraftTests {
    @Test func draftFieldsFromCleanedTranscript() async throws {
        let refiner = RuleBasedRefiner()
        let input = "um, create a climbing tracker app, keep it simple. Put it in my repos folder."
        let draft = try await refiner.refineCard(from: input, context: RefinementContext(mode: .command))
        #expect(draft.title == "Create a climbing tracker app")
        #expect(draft.summary == "Create a climbing tracker app, keep it simple.")
        #expect(draft.prompt == "Create a climbing tracker app, keep it simple. Put it in my repos folder.")
        #expect(draft.refinedByLLM == false)
    }

    @Test func titleTrimmedToLimitAtWordBoundary() {
        let cleaned = "Create a brand new web application that tracks all of my climbing sessions forever."
        let draft = RefinementRules.draftCard(fromCleaned: cleaned)
        #expect(draft.title.count <= 48)
        #expect(draft.title.hasSuffix("…"))
        #expect(!draft.title.contains(" that tracks all of my climbing sessions"))
    }

    @Test func shortTitleKeptVerbatimWithoutPunctuation() {
        let draft = RefinementRules.draftCard(fromCleaned: "Fix the build.")
        #expect(draft.title == "Fix the build")
        #expect(draft.summary == "Fix the build.")
    }

    @Test func emptyTranscriptYieldsEmptyDraft() async throws {
        let refiner = RuleBasedRefiner()
        let draft = try await refiner.refineCard(from: "  ", context: RefinementContext(mode: .command))
        #expect(draft.title.isEmpty)
        #expect(draft.prompt.isEmpty)
        #expect(draft.refinedByLLM == false)
    }

    @Test func rulesRefinerTestConnectionAlwaysSucceeds() async throws {
        try await RuleBasedRefiner().testConnection()
    }
}
