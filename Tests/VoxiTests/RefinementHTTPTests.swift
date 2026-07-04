import Foundation
import Testing
@testable import Voxi

/// URLProtocol stub for exercising the HTTP refiners without a network.
/// Handler + recording are global, so every test using it lives in the single
/// `.serialized` suite below.
final class MockURLProtocol: URLProtocol {
    struct Exchange: @unchecked Sendable {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _recorded: [Exchange] = []

    static func install(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        _handler = handler
        _recorded = []
    }

    static var recorded: [Exchange] {
        lock.lock()
        defer { lock.unlock() }
        return _recorded
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.bodyData(of: request)
        Self.lock.lock()
        Self._recorded.append(Exchange(request: request, body: body))
        let handler = Self._handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard status > 0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands POST bodies to URLProtocol as a stream, not httpBody.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func jsonBody(_ exchange: MockURLProtocol.Exchange) throws -> [String: Any] {
    let data = try #require(exchange.body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func openAIReply(_ content: String) -> Data {
    let payload: [String: Any] = [
        "id": "chatcmpl-1",
        "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func anthropicReply(_ text: String) -> Data {
    let payload: [String: Any] = [
        "id": "msg_1",
        "content": [["type": "text", "text": text]],
        "stop_reason": "end_turn",
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

@Suite(.serialized) struct RefinementHTTPTests {

    // MARK: - OpenAI-compatible

    @Test func openAIEndpointNormalization() throws {
        func path(_ base: String) throws -> String {
            OpenAICompatRefiner.endpoint(try #require(URL(string: base)), "chat/completions").absoluteString
        }
        #expect(try path("http://localhost:11434") == "http://localhost:11434/v1/chat/completions")
        #expect(try path("http://localhost:8080/v1") == "http://localhost:8080/v1/chat/completions")
        #expect(try path("http://localhost:8080/v1/") == "http://localhost:8080/v1/chat/completions")
        #expect(try path("http://host/proxy") == "http://host/proxy/v1/chat/completions")
    }

    @Test func openAIRefineRequestShapeAndResult() async throws {
        MockURLProtocol.install { _ in (200, openAIReply("Send the email to Sarah.")) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            apiKey: "secret-key",
            session: MockURLProtocol.makeSession()
        )

        let out = try await refiner.refine(
            "um send the email to sarah",
            context: RefinementContext(vocabulary: ["Sarah"])
        )
        #expect(out == "Send the email to Sarah.")

        let exchange = try #require(MockURLProtocol.recorded.first)
        #expect(exchange.request.url?.path == "/v1/chat/completions")
        #expect(exchange.request.httpMethod == "POST")
        #expect(exchange.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(exchange.request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try jsonBody(exchange)
        #expect(body["model"] as? String == "llama3.2")
        #expect(body["stream"] as? Bool == false)
        let temperature = try #require(body["temperature"] as? Double)
        #expect(abs(temperature - 0.2) < 0.0001)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect((messages[0]["content"] as? String)?.contains("Sarah") == true)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "um send the email to sarah")
    }

    @Test func openAIOmitsAuthorizationWithoutKey() async throws {
        MockURLProtocol.install { _ in (200, openAIReply("Hi.")) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            apiKey: nil,
            session: MockURLProtocol.makeSession()
        )
        _ = try await refiner.refine("hi there", context: RefinementContext())
        let exchange = try #require(MockURLProtocol.recorded.first)
        #expect(exchange.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func openAIRefineCardParsesFencedJSON() async throws {
        let fenced = "```json\n{\"title\":\"Build app\",\"summary\":\"Builds it\",\"prompt\":\"Build the app\"}\n```"
        MockURLProtocol.install { _ in (200, openAIReply(fenced)) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        let draft = try await refiner.refineCard(
            from: "build the app",
            context: RefinementContext(mode: .command)
        )
        #expect(draft.title == "Build app")
        #expect(draft.summary == "Builds it")
        #expect(draft.prompt == "Build the app")
        #expect(draft.refinedByLLM == true)
    }

    @Test func openAIServerErrorThrows() async {
        MockURLProtocol.install { _ in (500, Data("boom".utf8)) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        await #expect(throws: (any Error).self) {
            _ = try await refiner.refine("hello there", context: RefinementContext())
        }
    }

    @Test func openAIGarbageResponseThrows() async {
        MockURLProtocol.install { _ in (200, Data("not json".utf8)) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        await #expect(throws: (any Error).self) {
            _ = try await refiner.refine("hello there", context: RefinementContext())
        }
    }

    @Test func openAITestConnectionHitsModels() async throws {
        MockURLProtocol.install { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        try await refiner.testConnection()
        let exchange = try #require(MockURLProtocol.recorded.first)
        #expect(exchange.request.httpMethod == "GET")
        #expect(exchange.request.url?.path == "/v1/models")
    }

    @Test func openAITestConnectionFailureThrows() async {
        MockURLProtocol.install { _ in (404, Data()) }
        let refiner = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        await #expect(throws: (any Error).self) {
            try await refiner.testConnection()
        }
    }

    // MARK: - Anthropic

    @Test func anthropicRefineRequestShapeAndResult() async throws {
        MockURLProtocol.install { _ in (200, anthropicReply("Send the report to Sarah.")) }
        let refiner = AnthropicRefiner(
            apiKey: "sk-ant-test",
            session: MockURLProtocol.makeSession()
        )

        let out = try await refiner.refine(
            "send the report to sarah",
            context: RefinementContext(vocabulary: ["Sarah"])
        )
        #expect(out == "Send the report to Sarah.")

        let exchange = try #require(MockURLProtocol.recorded.first)
        #expect(exchange.request.url?.host == "api.anthropic.com")
        #expect(exchange.request.url?.path == "/v1/messages")
        #expect(exchange.request.httpMethod == "POST")
        #expect(exchange.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(exchange.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(exchange.request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try jsonBody(exchange)
        #expect(body["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect((body["system"] as? String)?.contains("Sarah") == true)
        let temperature = try #require(body["temperature"] as? Double)
        #expect(abs(temperature - 0.2) < 0.0001)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "send the report to sarah")
    }

    @Test func anthropicCustomModelIsSent() async throws {
        MockURLProtocol.install { _ in (200, anthropicReply("Ok.")) }
        let refiner = AnthropicRefiner(
            apiKey: "sk-ant-test",
            model: "claude-sonnet-4-5",
            session: MockURLProtocol.makeSession()
        )
        _ = try await refiner.refine("hello there", context: RefinementContext())
        let body = try jsonBody(try #require(MockURLProtocol.recorded.first))
        #expect(body["model"] as? String == "claude-sonnet-4-5")
    }

    @Test func anthropicRefineCardParsesJSON() async throws {
        let reply = "Here you go: {\"title\":\"Fix build\",\"summary\":\"Fixes it\",\"prompt\":\"Fix the build\"}"
        MockURLProtocol.install { _ in (200, anthropicReply(reply)) }
        let refiner = AnthropicRefiner(apiKey: "k", session: MockURLProtocol.makeSession())
        let draft = try await refiner.refineCard(
            from: "fix the build",
            context: RefinementContext(mode: .command)
        )
        #expect(draft.title == "Fix build")
        #expect(draft.refinedByLLM == true)
    }

    @Test func anthropicErrorStatusThrows() async {
        MockURLProtocol.install { _ in
            (401, Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8))
        }
        let refiner = AnthropicRefiner(apiKey: "bad", session: MockURLProtocol.makeSession())
        await #expect(throws: RefinerError.self) {
            _ = try await refiner.refine("hello there", context: RefinementContext())
        }
    }

    @Test func anthropicTestConnectionUsesOneToken() async throws {
        MockURLProtocol.install { _ in (200, anthropicReply("p")) }
        let refiner = AnthropicRefiner(apiKey: "k", session: MockURLProtocol.makeSession())
        try await refiner.testConnection()
        let exchange = try #require(MockURLProtocol.recorded.first)
        #expect(exchange.request.url?.path == "/v1/messages")
        let body = try jsonBody(exchange)
        #expect(body["max_tokens"] as? Int == 1)
        #expect(body["system"] == nil)
    }

    // MARK: - Chain fallback over HTTP

    @Test func chainFallsBackToRulesOnHTTPError() async throws {
        MockURLProtocol.install { _ in (500, Data()) }
        let llm = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        let chain = RefinerChain(llm: llm, rules: RuleBasedRefiner())
        let outcome = await chain.refine("um send the report", context: RefinementContext())
        #expect(outcome.text == "Send the report.")
        #expect(outcome.refinerID == "rules")
        #expect(outcome.usedLLM == false)
    }

    @Test func chainFallsBackOnNetworkFailure() async throws {
        MockURLProtocol.install { _ in (-1, Data()) } // simulated connection failure
        let llm = OpenAICompatRefiner(
            baseURL: URL(string: "http://localhost:11434")!,
            model: "llama3.2",
            session: MockURLProtocol.makeSession()
        )
        let chain = RefinerChain(llm: llm, rules: RuleBasedRefiner())
        let outcome = await chain.refineCard(from: "um build the thing", context: RefinementContext(mode: .command))
        #expect(outcome.refinerID == "rules")
        #expect(outcome.draft.refinedByLLM == false)
        #expect(outcome.draft.prompt == "Build the thing.")
    }
}
