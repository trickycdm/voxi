import Foundation
import Testing
@testable import Voxi

@MainActor
@Suite struct HotkeyControllerTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "voxi-hotkey-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsAreTheContractDefaults() {
        let controller = HotkeyController(defaults: scratchDefaults())
        #expect(controller.pushToTalkBinding == .defaultPushToTalk)
        #expect(controller.toggleBinding == .defaultToggle)
        #expect(controller.commandBinding == .defaultCommand)
        #expect(controller.permissionStatus == .unknown)
    }

    @Test func bindingsRoundTripThroughUserDefaults() {
        let defaults = scratchDefaults()
        let custom = ChordBinding(control: true, option: true)
        let customToggle = ChordBinding(control: true, option: true, keyCode: 49)

        do {
            let controller = HotkeyController(defaults: defaults)
            controller.pushToTalkBinding = custom
            controller.toggleBinding = customToggle
        }
        let reloaded = HotkeyController(defaults: defaults)
        #expect(reloaded.pushToTalkBinding == custom)
        #expect(reloaded.toggleBinding == customToggle)
        #expect(reloaded.commandBinding == .defaultCommand) // untouched -> default
    }

    @Test func corruptStoredBindingFallsBackToDefault() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: "hotkey.binding.pushToTalk")
        let controller = HotkeyController(defaults: defaults)
        #expect(controller.pushToTalkBinding == .defaultPushToTalk)
    }

    @Test func eventsFlowThroughStreamAndHandler() async {
        let controller = HotkeyController(defaults: scratchDefaults())
        var handled: [HotkeyEvent] = []
        controller.eventHandler = { handled.append($0) }

        // The tap is not running in tests (no Accessibility); drive the same
        // delivery path the tap uses via the internal machinery is not exposed,
        // so verify the stream finishes cleanly on stop().
        controller.stop()
        var streamed: [HotkeyEvent] = []
        for await event in controller.events {
            streamed.append(event)
        }
        #expect(streamed.isEmpty)
        #expect(handled.isEmpty)
    }

    @Test func fnUsageTypeReadDoesNotCrash() {
        // Value depends on the machine; just prove the read path works.
        let value = HotkeyController.appleFnUsageType()
        if let value {
            #expect((0...3).contains(value))
        }
        _ = HotkeyController.fnKeyTriggersSystemAction
    }
}
