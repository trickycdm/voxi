import Foundation

/// The rail footer's one-line engine status ("Parakeet · ready"). Pure so the
/// verdict is unit-testable; the rail feeds it synchronous registry reads.
struct EngineStatusLine: Equatable, Sendable {
    let text: String
    let isReady: Bool

    /// Shown before the first registry read lands.
    static let standby = EngineStatusLine(text: "standby", isReady: false)

    /// Engine display names carry a parenthetical provenance suffix
    /// ("Parakeet (FluidAudio)") that is noise at footer scale — keep the
    /// short name only.
    static func shortName(from displayName: String) -> String {
        guard let range = displayName.range(of: " (") else { return displayName }
        let short = String(displayName[..<range.lowerBound])
        return short.isEmpty ? displayName : short
    }

    /// Ready means the loaded engine IS the selected one — a stale load of a
    /// previously selected engine still reads standby.
    static func make(
        engineDisplayName: String,
        selectedEngineID: String,
        loadedEngineID: String?
    ) -> EngineStatusLine {
        let ready = loadedEngineID == selectedEngineID
        let name = shortName(from: engineDisplayName)
        return EngineStatusLine(
            text: "\(name) · \(ready ? "ready" : "standby")",
            isReady: ready)
    }
}
