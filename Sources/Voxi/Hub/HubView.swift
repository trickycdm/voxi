import SwiftUI

/// Content of the main Hub window: History, Dictionary, and Settings.
/// The shell wires it as `Window("Voxi Hub", id: "hub") { HubView() }` with
/// `.environment(appState)`.
struct HubView: View {
    enum HubSection: String, CaseIterable, Identifiable {
        case history
        case dictionary
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .history: "History"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .dictionary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @State private var selection: HubSection = .history

    var body: some View {
        HStack(spacing: 0) {
            HubRailView(selection: $selection)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.voxiPaper)
        }
        // Full bleed under the hidden titlebar; the rail owns the top edge.
        .ignoresSafeArea(.container, edges: .top)
        // Min width = rail 196 + History's HSplitView minimums (280 + 340).
        .frame(minWidth: 820, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .history:
            if let store = appState.historyStore {
                HistoryView(store: store)
            } else {
                databaseUnavailable
            }
        case .dictionary:
            if let store = appState.dictionaryStore {
                DictionaryView(store: store)
            } else {
                databaseUnavailable
            }
        case .settings:
            HubSettingsView()
        }
    }

    private var databaseUnavailable: some View {
        ContentUnavailableView(
            "Database Unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text(appState.lastError ?? "Voxi could not open its local database.")
        )
    }
}
