import SwiftUI

/// The Settings tab: one grouped Form assembling the per-concern sections.
struct HubSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            GeneralSettingsSection(inserter: appState.inserter)
            HotkeySettingsSection(hotkeys: appState.hotkeys)
            MicrophoneSettingsSection()
            SpeechSettingsSection(registry: appState.registry)
            RefinementSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
