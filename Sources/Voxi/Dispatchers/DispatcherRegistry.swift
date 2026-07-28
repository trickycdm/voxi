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

    /// What new cards are created with. The stored id is what "Run All"
    /// drains use; a dispatch button can override it at dispatch time.
    static let defaultDispatcherID = ClaudeCodeITermDispatcher.dispatcherID

    /// Interactive hand-off first, headless second — registration order is
    /// the card face's spec-union order.
    static func v1() -> DispatcherRegistry {
        DispatcherRegistry([ClaudeCodeITermDispatcher(), ClaudeCodeDispatcher()])
    }
}
