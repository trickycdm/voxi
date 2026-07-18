import SwiftUI

/// The Settings tab: one grouped Form assembling the per-concern sections.
struct HubSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HubPaneHeader("Settings")
            Form {
                GeneralSettingsSection(inserter: appState.inserter)
                HotkeySettingsSection(hotkeys: appState.hotkeys)
                MicrophoneSettingsSection()
                SpeechSettingsSection(registry: appState.registry)
                RefinementSettingsSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)  // let the Paper ground show through
        }
    }
}
