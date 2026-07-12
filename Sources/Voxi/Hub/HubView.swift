import SwiftUI

/// Content of the main Hub window: History, Dictionary, and Settings.
/// The shell wires it as `Window("Voxi Hub", id: "hub") { HubView() }` with
/// `.environment(appState)`.
struct HubView: View {
    enum HubSection: String, CaseIterable, Identifiable {
        case history
        case dictionary
        case settings

        // Identity must be Self, not String: List's implicit row tags come from
        // `id`, and they must match the `HubSection?` selection binding or
        // sidebar clicks are silently dropped.
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
    @State private var selection: HubSection? = .history

    var body: some View {
        NavigationSplitView {
            List(HubSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            Group {
                switch selection ?? .history {
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
            // Paper ground on the detail pane only; the sidebar keeps the
            // system vibrancy material (it resists .background on macOS 14).
            .background(Color.voxiPaper)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var databaseUnavailable: some View {
        ContentUnavailableView(
            "Database Unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text(appState.lastError ?? "Voxi could not open its local database.")
        )
    }
}
