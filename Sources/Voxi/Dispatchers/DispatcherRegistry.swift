import Foundation

/// Lookup table from a card's `dispatcherID` to its executor. Adding a new
/// executor means implementing `Dispatcher` and listing it here — nothing else.
struct DispatcherRegistry: Sendable {
    private let byID: [String: any Dispatcher]
    /// Registration order, for stable UI listings.
    let all: [any Dispatcher]

    init(_ dispatchers: [any Dispatcher]) {
        self.all = dispatchers
        self.byID = Dictionary(dispatchers.map { ($0.id, $0) }) { first, _ in first }
    }

    func dispatcher(id: String) -> (any Dispatcher)? {
        byID[id]
    }

    /// v1 ships exactly one dispatcher: Claude Code headless.
    static func v1() -> DispatcherRegistry {
        DispatcherRegistry([ClaudeCodeDispatcher()])
    }
}
