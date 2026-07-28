import Foundation
import Observation

/// The Hub's left-nav sections. Order defines the rail order and the
/// auto-generated ⌘1…⌘N shortcuts (HubRailView enumerates `allCases`).
enum HubSection: String, CaseIterable, Identifiable {
    case history
    case queue
    case dictionary
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .history: "History"
        case .queue: "Queue"
        case .dictionary: "Dictionary"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .queue: "rectangle.stack"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

/// Externally settable Hub navigation state, owned by HubWindowController so
/// AppState can deep-link (menu bar, notification taps) into a section — the
/// window is controller-owned AppKit, so there is no scene environment to
/// route through.
@MainActor @Observable
final class HubRouter {
    var section: HubSection = .history
    /// Card the queue pane should select on next appearance (notification
    /// deep-link); consumed and cleared by QueuePaneView.
    var pendingQueueCardID: UUID?
}
