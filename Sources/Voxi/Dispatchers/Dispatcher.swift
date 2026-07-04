import Foundation

/// Streaming updates from a running dispatch.
enum DispatchEvent: Sendable {
    /// A line of output to append to the card's log.
    case log(String)
    /// Short human-readable activity, e.g. "running Bash", shown live on the card.
    case activity(String)
}

struct DispatchResult: Sendable {
    var success: Bool
    var exitCode: Int?
    /// Final summary line for the card (e.g. claude's result text or an error).
    var resultText: String?
}

/// One parameter a dispatcher accepts, for generic parameter UI.
struct DispatcherParamSpec: Identifiable, Sendable {
    enum Kind: Sendable {
        case directory      // rendered as a directory picker with recents
        case string
    }
    /// Key in the card's params JSON object.
    let id: String
    let label: String
    let kind: Kind
    let required: Bool
}

enum DispatcherError: Error, LocalizedError {
    case executableNotFound(String)
    case invalidParams(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let what): "Executable not found: \(what)"
        case .invalidParams(let why): "Invalid dispatch parameters: \(why)"
        case .spawnFailed(let why): "Failed to start process: \(why)"
        }
    }
}

/// A pluggable executor for action cards. v1 ships exactly one implementation
/// (Claude Code headless); new executors implement this and register — nothing else.
protocol Dispatcher: Sendable {
    var id: String { get }
    var displayName: String { get }
    var paramSpecs: [DispatcherParamSpec] { get }

    /// Execute the card's prompt. Streams events while running; the returned
    /// result decides succeeded/failed. Must honor task cancellation by
    /// terminating the underlying work.
    func execute(
        prompt: String,
        params: [String: String],
        onEvent: @escaping @Sendable (DispatchEvent) -> Void
    ) async throws -> DispatchResult
}
