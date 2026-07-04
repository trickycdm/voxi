import Foundation

/// UserDefaults-backed MRU list of working directories for the queue UI's
/// directory picker. Most recent first, deduplicated, capped at 10.
/// @unchecked: UserDefaults is documented thread-safe but this SDK does not
/// mark it Sendable.
struct RecentDirectories: @unchecked Sendable {
    static let defaultsKey = "voxi.recentDirs"
    static let capacity = 10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var entries: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Record a use: moves (or inserts) the path to the front, drops overflow.
    func noteUse(of path: String) {
        var list = entries
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > Self.capacity {
            list.removeLast(list.count - Self.capacity)
        }
        defaults.set(list, forKey: Self.defaultsKey)
    }

    func remove(_ path: String) {
        let list = entries.filter { $0 != path }
        defaults.set(list, forKey: Self.defaultsKey)
    }
}
