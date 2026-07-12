import Foundation

/// Pure resolution of which input-device name the pill should display for a
/// session. Mirrors AudioCapture.start's device fallback: a nil or unknown
/// saved UID means capture runs on the system default input, so the label
/// must say the same. Unit-tested in CaptureDeviceNamingTests.
enum InputDeviceNaming {
    static func resolvedName(uid: String?, devices: [AudioInputDevice]) -> String? {
        guard !devices.isEmpty else { return nil }
        if let uid, let match = devices.first(where: { $0.id == uid }) {
            return match.name
        }
        return (devices.first(where: { $0.isDefault }) ?? devices[0]).name
    }
}
