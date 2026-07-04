import Foundation

/// Cloud refiner against the Anthropic Messages API with a user-supplied key.
/// The only network call in Voxi that leaves the machine, and strictly opt-in.
struct AnthropicRefiner: Refiner {
    static let defaultModel = "claude-haiku-4-5-20251001"
    static let apiVersion = "2023-06-01"

    let id = "anthropic"
    let displayName = "Anthropic API"

    let apiKey: String
    let model: String
    private let baseURL: URL
    private let session: URLSession

    init(
        apiKey: String,
        model: String = AnthropicRefiner.defaultModel,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
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
        // Cheapest possible round trip: a 1-token completion validates the
        // key, the model id, and connectivity in one call.
        _ = try await send(system: nil, user: "ping", maxTokens: 1, requireText: false)
    }

    // MARK: - Transport

    private struct MessagesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let temperature: Double

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case temperature
        }
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private func complete(system: String, user: String) async throws -> String {
        try await send(system: system, user: user, maxTokens: 1024, requireText: true)
    }

    @discardableResult
    private func send(system: String?, user: String, maxTokens: Int, requireText: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: user)],
            temperature: 0.2
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RefinerError.badResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw RefinerError.badResponse("HTTP \(http.statusCode) \(detail)")
        }
        let text = (try? JSONDecoder().decode(MessagesResponse.self, from: data))?
            .content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined() ?? ""
        if requireText, text.isEmpty {
            throw RefinerError.badResponse("no text content in messages response")
        }
        return text
    }
}
