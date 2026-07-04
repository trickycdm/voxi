import Foundation

/// Local-LLM refiner speaking the OpenAI chat-completions dialect — covers
/// Ollama, LM Studio, and llama.cpp servers with a user-supplied base URL.
struct OpenAICompatRefiner: Refiner {
    let id = "openai-compat"
    let displayName = "Local LLM (OpenAI-compatible)"

    let baseURL: URL
    let model: String
    let apiKey: String?
    private let session: URLSession

    init(baseURL: URL, model: String, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Refiner

    func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let text = try await complete(
            system: LLMPrompts.dictationSystem(vocabulary: context.vocabulary),
            user: trimmed
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refineCard(from transcript: String, context: RefinementContext) async throws -> CardDraft {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RefinerError.badResponse("empty transcript")
        }
        let text = try await complete(
            system: LLMPrompts.cardSystem(vocabulary: context.vocabulary),
            user: trimmed
        )
        return try LenientJSON.decode(CardPayload.self, from: text).draft
    }

    func testConnection() async throws {
        var request = URLRequest(url: Self.endpoint(baseURL, "models"))
        request.httpMethod = "GET"
        applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        try Self.checkStatus(response)
    }

    // MARK: - Transport

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: Self.endpoint(baseURL, "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: 0.2,
            stream: false
        ))
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, body: data)
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content,
            !content.isEmpty else {
            throw RefinerError.badResponse("no message content in chat completion")
        }
        return content
    }

    private func applyAuth(to request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Builds `{base}/v1/{suffix}`, tolerating base URLs given with or
    /// without a trailing `/v1` (and with or without a trailing slash).
    static func endpoint(_ base: URL, _ suffix: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        if !root.lowercased().hasSuffix("/v1") { root += "/v1" }
        guard let url = URL(string: root + "/" + suffix) else {
            // base was a valid URL, so appending a fixed path cannot fail in practice
            return base.appendingPathComponent(suffix)
        }
        return url
    }

    private static func checkStatus(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RefinerError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = body.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? ""
            throw RefinerError.badResponse("HTTP \(http.statusCode) \(detail)")
        }
    }
}
