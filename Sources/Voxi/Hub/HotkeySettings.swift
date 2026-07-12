import AppKit
import SwiftUI

struct HotkeySettingsSection: View {
    @Bindable var hotkeys: HotkeyController

    var body: some View {
        Section {
            LabeledContent("Push to talk") {
                ChordRecorderView(chord: $hotkeys.pushToTalkBinding)
            }
            LabeledContent("Hands-free toggle") {
                ChordRecorderView(chord: $hotkeys.toggleBinding)
            }
            LabeledContent("Command mode") {
                ChordRecorderView(chord: $hotkeys.commandBinding)
            }

            permissionRow

            if fnWarningNeeded {
                LabeledContent {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(HotkeyController.keyboardSettingsURL)
                    }
                } label: {
                    Label(
                        "The 🌐 key also triggers a system action. Set “Press 🌐 key to: Do Nothing” in Keyboard settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(Color.voxiWarning)
                }
            }
        } header: {
            Text("Hotkeys").voxiPlaque()
        } footer: {
            Text("Click a field, then press the chord — modifier-only chords like Fn or ⌃⌥ work. Esc or click away to cancel.")
        }
    }

    private var permissionRow: some View {
        LabeledContent("Accessibility permission") {
            HStack(spacing: 8) {
                statusLabel
                if hotkeys.permissionStatus != .active {
                    Button("Open Accessibility Settings") {
                        hotkeys.requestAccessibility()
                        NSWorkspace.shared.open(HotkeyController.accessibilitySettingsURL)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch hotkeys.permissionStatus {
        case .active:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.voxiSuccess)
        case .waitingForTrust:
            Label("Not granted — hotkeys inactive", systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.voxiWarning)
        case .tapFailed:
            Label("Event tap failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.voxiDanger)
        case .unknown:
            Label("Checking…", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private var fnWarningNeeded: Bool {
        guard HotkeyController.fnKeyTriggersSystemAction else { return false }
        return hotkeys.pushToTalkBinding.includesFn
            || hotkeys.toggleBinding.includesFn
            || hotkeys.commandBinding.includesFn
    }
}
