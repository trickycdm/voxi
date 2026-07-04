import Foundation

/// Final `result` event of a claude stream-json run.
struct ClaudeRunResult: Equatable, Sendable {
    var subtype: String?
    var isError: Bool
    /// Final assistant text. JSON `null` (or absent) on error_max_turns.
    var resultText: String?
    var totalCostUSD: Double?
    var numTurns: Int?
    var durationMS: Int?
    var permissionDenialCount: Int
}

/// The events Voxi cares about from `claude -p --output-format stream-json`.
/// Everything else on the stream (rate_limit_event, system/status,
/// system/thinking_tokens, stream_event, user/tool_result, thinking blocks, …)
/// is deliberately dropped.
enum ClaudeEvent: Equatable, Sendable {
    case initialized(sessionID: String, model: String)
    case assistantText(String)
    case toolUse(name: String, summary: String?)
    case result(ClaudeRunResult)
}

/// Incremental NDJSON parser for the claude CLI's stream-json output.
/// Feed raw stdout chunks; get back decoded `ClaudeEvent`s. Lines can be
/// hundreds of KB (tool_results embed file contents) — no length cap.
/// Unknown event types/subtypes and undecodable lines are silently skipped:
/// new event kinds appear between CLI versions and must never be errors.
struct StreamJSONParser: Sendable {
    private var buffer = Data()

    /// Consume a chunk of stdout; returns events for every complete line seen.
    mutating func consume(_ chunk: Data) -> [ClaudeEvent] {
        buffer.append(chunk)
        var events: [ClaudeEvent] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            events.append(contentsOf: Self.events(fromLine: line))
        }
        return events
    }

    /// Parse any trailing data not terminated by a newline (call at EOF).
    mutating func finish() -> [ClaudeEvent] {
        defer { buffer.removeAll() }
        return Self.events(fromLine: buffer)
    }

    static func events(fromLine rawLine: Data) -> [ClaudeEvent] {
        var line = rawLine
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard !line.isEmpty else { return [] }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return [] }

        switch envelope.type {
        case "system" where envelope.subtype == "init":
            guard let payload = try? decoder.decode(InitPayload.self, from: line) else { return [] }
            return [.initialized(sessionID: payload.sessionID ?? "?", model: payload.model ?? "?")]
        case "assistant":
            guard let payload = try? decoder.decode(AssistantPayload.self, from: line) else { return [] }
            return payload.message.content.compactMap { block in
                switch block.type {
                case "text":
                    guard let text = block.text, !text.isEmpty else { return nil }
                    return .assistantText(text)
                case "tool_use":
                    guard let name = block.name else { return nil }
                    return .toolUse(name: name, summary: Self.toolSummary(from: block.input))
                default:
                    return nil   // thinking, redacted_thinking, future block types
                }
            }
        case "result":
            guard let payload = try? decoder.decode(ResultPayload.self, from: line) else { return [] }
            return [.result(ClaudeRunResult(
                subtype: envelope.subtype,
                isError: payload.isError ?? false,
                resultText: payload.result,
                totalCostUSD: payload.totalCostUSD,
                numTurns: payload.numTurns,
                durationMS: payload.durationMS,
                permissionDenialCount: payload.permissionDenials?.count ?? 0))]
        default:
            return []
        }
    }

    /// Best human-readable one-liner for a tool_use input, e.g. "git status"
    /// for Bash or the file path for Write/Edit/Read.
    static func toolSummary(from input: JSONValue?) -> String? {
        guard case .object(let fields)? = input else { return nil }
        let priorityKeys = ["command", "file_path", "path", "pattern", "url", "query", "prompt", "description"]
        for key in priorityKeys {
            if case .string(let value)? = fields[key], !value.isEmpty {
                return abbreviated(value)
            }
        }
        return nil
    }

    private static func abbreviated(_ value: String, limit: Int = 120) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count <= limit ? oneLine : String(oneLine.prefix(limit)) + "…"
    }
}

// MARK: - Wire payloads

private struct Envelope: Decodable {
    let type: String
    let subtype: String?
}

private struct InitPayload: Decodable {
    let sessionID: String?
    let model: String?
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case model
    }
}

private struct AssistantPayload: Decodable {
    struct Message: Decodable {
        let content: [Block]
    }
    struct Block: Decodable {
        let type: String
        let text: String?
        let name: String?
        let input: JSONValue?
    }
    let message: Message
}

private struct ResultPayload: Decodable {
    let isError: Bool?
    let result: String?     // JSON null on error_max_turns — must stay Optional
    let totalCostUSD: Double?
    let numTurns: Int?
    let durationMS: Int?
    let permissionDenials: [JSONValue]?
    enum CodingKeys: String, CodingKey {
        case isError = "is_error"
        case result
        case totalCostUSD = "total_cost_usd"
        case numTurns = "num_turns"
        case durationMS = "duration_ms"
        case permissionDenials = "permission_denials"
    }
}

/// Minimal untyped JSON for tool_use inputs, whose schema is tool-defined.
enum JSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}
