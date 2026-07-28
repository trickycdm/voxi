import SwiftUI

/// Content of the main Hub window: History, Queue, Dictionary, and Settings.
/// Hosted by HubWindowController in a controller-owned NSWindow; navigation
/// state lives in HubRouter so AppState can deep-link sections.
struct HubView: View {
    @Bindable var router: HubRouter

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            HubRailView(selection: $router.section)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.voxiPaper)
        }
        // Full bleed under the hidden titlebar; the rail owns the top edge.
        .ignoresSafeArea(.container, edges: .top)
        // Rail 196 + queue master–detail split (window enforces contentMinSize).
        .frame(minWidth: 880, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
        case .history:
            if let store = appState.historyStore {
                HistoryView(store: store)
            } else {
                databaseUnavailable
            }
        case .queue:
            if let model = appState.queueModel,
                let runner = appState.queueRunner,
                let resolver = appState.dispatcherResolver
            {
                QueuePaneView(
                    model: model,
                    runner: runner,
                    resolver: resolver,
                    openLog: { [weak appState] card in appState?.logWindows?.show(card: card) },
                    pendingCardID: $router.pendingQueueCardID
                )
            } else {
                databaseUnavailable
            }
        case .dictionary:
            if let store = appState.dictionaryStore,
                let learnedStore = appState.learnedCorrectionStore
            {
                DictionaryView(store: store, learnedStore: learnedStore)
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
