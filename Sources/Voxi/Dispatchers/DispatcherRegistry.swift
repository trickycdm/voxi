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

    /// What new cards are created with; the picker lets the user switch a
    /// queued card to any registered dispatcher.
    static let defaultDispatcherID = ClaudeCodeITermDispatcher.dispatcherID

    /// Interactive hand-off first (the default tops the picker), headless second.
    static func v1() -> DispatcherRegistry {
        DispatcherRegistry([ClaudeCodeITermDispatcher(), ClaudeCodeDispatcher()])
    }
}
