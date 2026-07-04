import Testing
@testable import Voxi

@Suite struct RefinementJSONTests {
    @Test func plainJSONObject() throws {
        let payload = try LenientJSON.decode(
            CardPayload.self,
            from: #"{"title":"T","summary":"S","prompt":"P"}"#
        )
        #expect(payload.title == "T")
        #expect(payload.summary == "S")
        #expect(payload.prompt == "P")
    }

    @Test func fencedJSON() throws {
        let text = """
        ```json
        {"title":"Build app","summary":"Builds the app","prompt":"Build the app now"}
        ```
        """
        let payload = try LenientJSON.decode(CardPayload.self, from: text)
        #expect(payload.title == "Build app")
    }

    @Test func bareFenceWithoutLanguageTag() throws {
        let text = "```\n{\"title\":\"T\",\"summary\":\"S\",\"prompt\":\"P\"}\n```"
        let payload = try LenientJSON.decode(CardPayload.self, from: text)
        #expect(payload.prompt == "P")
    }

    @Test func prefixedCommentaryBeforeJSON() throws {
        let text = #"Here is the JSON you asked for: {"title":"T","summary":"S","prompt":"P"} Hope that helps!"#
        let payload = try LenientJSON.decode(CardPayload.self, from: text)
        #expect(payload.summary == "S")
    }

    @Test func nestedBracesInsideValues() throws {
        let text = #"{"title":"T","summary":"S","prompt":"Use {curly} braces"}"#
        let payload = try LenientJSON.decode(CardPayload.self, from: text)
        #expect(payload.prompt == "Use {curly} braces")
    }

    @Test func missingJSONThrows() {
        #expect(throws: RefinerError.self) {
            _ = try LenientJSON.decode(CardPayload.self, from: "Sorry, I cannot help with that.")
        }
    }

    @Test func wrongShapeThrows() {
        #expect(throws: RefinerError.self) {
            _ = try LenientJSON.decode(CardPayload.self, from: #"{"heading":"T"}"#)
        }
    }

    @Test func payloadDraftClampsTitleAndTrims() throws {
        let long = String(repeating: "a", count: 80)
        let payload = try LenientJSON.decode(
            CardPayload.self,
            from: #"{"title":"\#(long)","summary":" S ","prompt":" P "}"#
        )
        let draft = payload.draft
        #expect(draft.title.count == 48)
        #expect(draft.summary == "S")
        #expect(draft.prompt == "P")
        #expect(draft.refinedByLLM == true)
    }
}
