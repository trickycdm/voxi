import ServiceManagement
import SwiftUI

/// Launch-at-login via SMAppService.mainApp. Status is re-read after every
/// register/unregister — never cached optimistically.
@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            voxiLog.warning("Launch-at-login change failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Insertion settings persistence + live application to the running
/// TextInserter. Round-trip tested with injected UserDefaults.
@MainActor
@Observable
final class InsertionSettingsModel {
    var settings: InsertionSettings {
        didSet {
            settings.save(to: defaults)
            apply?(settings)
        }
    }

    /// Pushes saved settings into the live TextInserter.
    var apply: ((InsertionSettings) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = .load(from: defaults)
    }
}

extension InsertionMethod {
    var hubDisplayName: String {
        switch self {
        case .auto: "Automatic (Accessibility, then clipboard)"
        case .pasteboardAlways: "Clipboard paste (⌘V) always"
        case .appleScript: "AppleScript paste (needs Automation permission)"
        }
    }
}

struct GeneralSettingsSection: View {
    let inserter: TextInserter?

    @State private var launch = LaunchAtLoginModel()
    @State private var insertion = InsertionSettingsModel()

    var body: some View {
        Section("General") {
            Toggle(
                "Launch Voxi at login",
                isOn: Binding(
                    get: { launch.isEnabled },
                    set: { launch.setEnabled($0) }
                )
            )
            if launch.requiresApproval {
                LabeledContent {
                    Button("Open Login Items Settings") {
                        launch.openLoginItemsSettings()
                    }
                } label: {
                    Label(
                        "Waiting for approval in System Settings › Login Items",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            if let error = launch.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Insert text using", selection: $insertion.settings.method) {
                ForEach(InsertionMethod.allCases, id: \.self) { method in
                    Text(method.hubDisplayName).tag(method)
                }
            }
            Toggle("Restore clipboard after paste", isOn: $insertion.settings.restoreClipboard)
        }
        .onAppear {
            launch.refresh()
            insertion.apply = { [weak inserter] settings in
                inserter?.settings = settings
            }
        }
    }
}
