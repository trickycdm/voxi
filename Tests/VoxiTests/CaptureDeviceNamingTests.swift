import Foundation
import Testing
@testable import Voxi

@Suite("Input device naming — pill label resolution")
struct CaptureDeviceNamingTests {
    let builtIn = AudioInputDevice(id: "uid-builtin", name: "MacBook Pro Microphone", isDefault: true)
    let airpods = AudioInputDevice(id: "uid-airpods", name: "AirPods Pro", isDefault: false)

    @Test("nil UID resolves to the default device's name")
    func nilUIDUsesDefault() {
        let name = InputDeviceNaming.resolvedName(uid: nil, devices: [airpods, builtIn])
        #expect(name == "MacBook Pro Microphone")
    }

    @Test("matching UID resolves to that device's name")
    func matchedUID() {
        let name = InputDeviceNaming.resolvedName(uid: "uid-airpods", devices: [airpods, builtIn])
        #expect(name == "AirPods Pro")
    }

    @Test("unknown UID falls back to the default device, mirroring AudioCapture.start")
    func unknownUIDFallsBack() {
        let name = InputDeviceNaming.resolvedName(uid: "uid-unplugged", devices: [airpods, builtIn])
        #expect(name == "MacBook Pro Microphone")
    }

    @Test("no default flag anywhere still yields a name (first device)")
    func noDefaultFlag() {
        let noDefault = AudioInputDevice(id: "uid-x", name: "USB Interface", isDefault: false)
        let name = InputDeviceNaming.resolvedName(uid: nil, devices: [noDefault, airpods])
        #expect(name == "USB Interface")
    }

    @Test("empty device list yields nil — no label rather than a wrong one")
    func emptyList() {
        #expect(InputDeviceNaming.resolvedName(uid: "uid-airpods", devices: []) == nil)
    }

    @Test("duplicate UIDs resolve to the first match, deterministically")
    func duplicateUIDs() {
        let dupe = AudioInputDevice(id: "uid-airpods", name: "AirPods Pro (2)", isDefault: false)
        let name = InputDeviceNaming.resolvedName(uid: "uid-airpods", devices: [airpods, dupe])
        #expect(name == "AirPods Pro")
    }
}
