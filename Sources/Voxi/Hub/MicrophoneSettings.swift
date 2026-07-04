import SwiftUI

/// Input-device selection persisted to the UserDefaults key the coordinator
/// reads at capture start. Round-trip tested with injected defaults.
@MainActor
@Observable
final class MicrophoneModel {
    static let defaultsKey = "audio.inputDeviceUID"

    /// nil = follow the system default input.
    var selectedUID: String? {
        didSet {
            if let uid = selectedUID {
                defaults.set(uid, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    private(set) var devices: [AudioInputDevice] = []

    private let defaults: UserDefaults
    private let listDevices: @Sendable () -> [AudioInputDevice]

    init(
        defaults: UserDefaults = .standard,
        listDevices: @escaping @Sendable () -> [AudioInputDevice] = { AudioCapture.listInputDevices() }
    ) {
        self.defaults = defaults
        self.listDevices = listDevices
        selectedUID = defaults.string(forKey: Self.defaultsKey)
    }

    func refreshDevices() {
        devices = listDevices()
    }

    /// The device Voxi will actually record from right now.
    var activeDeviceName: String {
        let systemDefault = devices.first(where: \.isDefault)?.name ?? "System default"
        guard let uid = selectedUID else { return systemDefault }
        if let device = devices.first(where: { $0.id == uid }) {
            return device.name
        }
        return "\(systemDefault) (selected device unavailable)"
    }

    /// True when the persisted selection is not currently attached.
    var selectionUnavailable: Bool {
        guard let uid = selectedUID else { return false }
        return !devices.contains { $0.id == uid }
    }
}

struct MicrophoneSettingsSection: View {
    @State private var model = MicrophoneModel()

    var body: some View {
        Section {
            LabeledContent("Active input") {
                Label(model.activeDeviceName, systemImage: "mic.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(model.selectionUnavailable ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            }

            Picker("Input device", selection: $model.selectedUID) {
                Text("System default").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
                if model.selectionUnavailable, let uid = model.selectedUID {
                    Text("Unavailable device").tag(String?.some(uid))
                }
            }

            Button("Refresh Devices", systemImage: "arrow.clockwise") {
                model.refreshDevices()
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("The system default follows whatever macOS is using. A specific device is used only while it is connected.")
        }
        .task { model.refreshDevices() }
    }
}
