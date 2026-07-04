import CoreGraphics
import Foundation
import Testing
@testable import Voxi

// MARK: - Test driver

private let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
private let ctrlFlag = CGEventFlags.maskControl.rawValue
private let optFlag = CGEventFlags.maskAlternate.rawValue
private let shiftFlag = CGEventFlags.maskShift.rawValue
private let capsFlag = CGEventFlags.maskAlphaShift.rawValue

private let kcFn: UInt16 = 63
private let kcCtrl: UInt16 = 59
private let kcOpt: UInt16 = 58
private let kcShift: UInt16 = 56
private let kcSpace: UInt16 = 49
private let kcEsc: UInt16 = 53
private let kcLeftArrow: UInt16 = 123
private let kcA: UInt16 = 0

/// Scripts events into a ChordStateMachine with realistic key codes and flags.
private struct Driver {
    var machine: ChordStateMachine

    init(bindings: ChordStateMachine.Bindings = .defaults) {
        machine = ChordStateMachine(bindings: bindings)
    }

    @discardableResult
    mutating func flags(_ keyCode: UInt16, _ flags: UInt64) -> (event: HotkeyEvent?, swallow: Bool) {
        machine.handle(kind: .flagsChanged, keyCode: keyCode, flags: flags)
    }

    @discardableResult
    mutating func keyDown(_ keyCode: UInt16, flags: UInt64 = 0, isRepeat: Bool = false) -> (event: HotkeyEvent?, swallow: Bool) {
        machine.handle(kind: .keyDown, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }

    @discardableResult
    mutating func keyUp(_ keyCode: UInt16, flags: UInt64 = 0) -> (event: HotkeyEvent?, swallow: Bool) {
        machine.handle(kind: .keyUp, keyCode: keyCode, flags: flags)
    }

    @discardableResult
    mutating func fnDown() -> (event: HotkeyEvent?, swallow: Bool) { flags(kcFn, fnFlag) }
    @discardableResult
    mutating func fnUp() -> (event: HotkeyEvent?, swallow: Bool) { flags(kcFn, 0) }
}

// MARK: - Push-to-talk

@Suite struct PushToTalkTests {
    @Test func pressAndReleaseCommits() {
        var d = Driver()
        let press = d.fnDown()
        #expect(press.event == .actionBegan(.pushToTalk))
        #expect(!press.swallow)
        #expect(d.machine.isSessionActive)

        let release = d.fnUp()
        #expect(release.event == .actionEnded(.pushToTalk))
        #expect(!release.swallow)
        #expect(!d.machine.isSessionActive)
    }

    @Test func fnPlusArrowAborts() {
        var d = Driver()
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))

        // Arrow keyDown carries the spurious secondary-fn flag; it must pass through.
        let arrow = d.keyDown(kcLeftArrow, flags: fnFlag)
        #expect(arrow.event == .aborted)
        #expect(!arrow.swallow)
        #expect(!d.machine.isSessionActive)

        // Further keys while Fn is still held pass through silently.
        let again = d.keyDown(kcLeftArrow, flags: fnFlag)
        #expect(again.event == nil)
        #expect(!again.swallow)
        #expect(d.keyUp(kcLeftArrow, flags: fnFlag) == (nil, false))

        // Releasing Fn emits nothing (session already aborted)...
        #expect(d.fnUp() == (nil, false))
        // ...and PTT re-arms afterwards.
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
    }

    @Test func extraUnboundModifierDoesNotAbortHold() {
        var d = Driver()
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
        // Fn+Shift matches no binding: keep holding (a bound keyDown may follow).
        #expect(d.flags(kcShift, fnFlag | shiftFlag) == (nil, false))
        #expect(d.machine.isSessionActive)
        #expect(d.flags(kcShift, fnFlag) == (nil, false))
        #expect(d.fnUp().event == .actionEnded(.pushToTalk))
    }

    @Test func capsLockGlitchIsIgnored() {
        var d = Driver()
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
        // Caps lock toggles a flag we don't track: no modifier change, no event.
        #expect(d.flags(57, fnFlag | capsFlag) == (nil, false))
        #expect(d.fnUp().event == .actionEnded(.pushToTalk))
    }

    @Test func spuriousFnFlagOnOtherModifierDoesNotStartPTT() {
        var d = Driver()
        // A ctrl flagsChanged carrying the secondary-fn bit without a prior
        // keyCode-63 event must not be treated as physical Fn.
        let r = d.flags(kcCtrl, ctrlFlag | fnFlag)
        #expect(r.event == nil)
        #expect(!d.machine.isSessionActive)
    }
}

// MARK: - Ctrl+Opt alternative chord

@Suite struct CtrlOptChordTests {
    private var bindings: ChordStateMachine.Bindings {
        var b = ChordStateMachine.Bindings.defaults
        b.pushToTalk = ChordBinding(control: true, option: true)
        return b
    }

    @Test func pressEdgeStartsReleaseEdgeCommits() {
        var d = Driver(bindings: bindings)
        #expect(d.flags(kcCtrl, ctrlFlag) == (nil, false))
        let press = d.flags(kcOpt, ctrlFlag | optFlag)
        #expect(press.event == .actionBegan(.pushToTalk))

        // Either modifier dropping is the release edge.
        let release = d.flags(kcOpt, ctrlFlag)
        #expect(release.event == .actionEnded(.pushToTalk))
        // The remaining Ctrl release does nothing.
        #expect(d.flags(kcCtrl, 0) == (nil, false))
    }

    @Test func deviceDependentBitsAreIgnored() {
        var d = Driver(bindings: bindings)
        // Left-control / left-option device bits set alongside the independent masks.
        let leftDeviceBits: UInt64 = 0x0000_0001 | 0x0000_0020
        let press = d.flags(kcOpt, ctrlFlag | optFlag | leftDeviceBits)
        #expect(press.event == .actionBegan(.pushToTalk))
        #expect(d.flags(kcCtrl, optFlag | 0x0000_0020).event == .actionEnded(.pushToTalk))
    }

    @Test func unboundKeyWhileChordHeldAborts() {
        var d = Driver(bindings: bindings)
        d.flags(kcCtrl, ctrlFlag)
        #expect(d.flags(kcOpt, ctrlFlag | optFlag).event == .actionBegan(.pushToTalk))
        // Ctrl+Opt+A is a real shortcut somewhere: abort and pass through.
        let key = d.keyDown(kcA, flags: ctrlFlag | optFlag)
        #expect(key.event == .aborted)
        #expect(!key.swallow)
    }
}

// MARK: - Toggle latch (Fn+Space)

@Suite struct ToggleLatchTests {
    @Test func latchOnThenOff() {
        var d = Driver()
        // Fn down tentatively begins PTT...
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
        // ...and Space converts it into the latch. Space must be swallowed.
        let latch = d.keyDown(kcSpace, flags: fnFlag)
        #expect(latch.event == .actionBegan(.toggleDictation))
        #expect(latch.swallow)
        #expect(d.keyUp(kcSpace, flags: fnFlag) == (nil, true))

        // Fn release keeps the latch alive.
        #expect(d.fnUp() == (nil, false))
        #expect(d.machine.isSessionActive)

        // Normal typing during hands-free dictation passes through and does not abort.
        #expect(d.keyDown(kcA) == (nil, false))
        #expect(d.keyUp(kcA) == (nil, false))
        #expect(d.machine.isSessionActive)

        // Second Fn+Space unlatches; both Space edges swallowed, Fn press suppressed.
        #expect(d.fnDown() == (nil, false))
        let unlatch = d.keyDown(kcSpace, flags: fnFlag)
        #expect(unlatch.event == .actionEnded(.toggleDictation))
        #expect(unlatch.swallow)
        #expect(d.keyUp(kcSpace, flags: fnFlag) == (nil, true))
        #expect(d.fnUp() == (nil, false))
        #expect(!d.machine.isSessionActive)

        // Machine fully re-arms afterwards.
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
    }

    @Test func spaceAutoRepeatDoesNotFlapTheLatch() {
        var d = Driver()
        d.fnDown()
        #expect(d.keyDown(kcSpace, flags: fnFlag).event == .actionBegan(.toggleDictation))
        // Holding Fn+Space auto-repeats: swallowed, but no latch flapping.
        let repeated = d.keyDown(kcSpace, flags: fnFlag, isRepeat: true)
        #expect(repeated.event == nil)
        #expect(repeated.swallow)
        #expect(d.machine.isSessionActive)
    }

    @Test func spaceWithoutChordModifiersPassesThrough() {
        var d = Driver()
        let space = d.keyDown(kcSpace)
        #expect(space.event == nil)
        #expect(!space.swallow)
        #expect(d.keyUp(kcSpace) == (nil, false))
    }

    @Test func chordPressWhileLatchedIsSuppressed() {
        var d = Driver()
        d.fnDown()
        d.keyDown(kcSpace, flags: fnFlag)
        d.keyUp(kcSpace, flags: fnFlag)
        d.fnUp()
        // While latched, holding Fn must not begin a second (PTT) session.
        #expect(d.fnDown() == (nil, false))
        #expect(d.fnUp() == (nil, false))
        #expect(d.machine.isSessionActive)
    }
}

// MARK: - Command chord (Fn+Ctrl)

@Suite struct CommandChordTests {
    @Test func upgradeFromPTTHold() {
        var d = Driver()
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
        // Adding Ctrl upgrades the running hold to command mode.
        let upgrade = d.flags(kcCtrl, fnFlag | ctrlFlag)
        #expect(upgrade.event == .actionBegan(.commandMode))
        #expect(!upgrade.swallow)

        // Releasing either modifier commits the command dictation.
        let release = d.flags(kcCtrl, fnFlag)
        #expect(release.event == .actionEnded(.commandMode))
        // The still-held Fn must NOT re-arm PTT until everything is up.
        #expect(d.flags(kcCtrl, fnFlag | ctrlFlag) == (nil, false))
        #expect(d.flags(kcCtrl, fnFlag) == (nil, false))
        #expect(d.fnUp() == (nil, false))
        // Fully released: PTT works again.
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
    }

    @Test func ctrlFirstOrderStartsCommandDirectly() {
        var d = Driver()
        #expect(d.flags(kcCtrl, ctrlFlag) == (nil, false))
        let press = d.flags(kcFn, ctrlFlag | fnFlag)
        #expect(press.event == .actionBegan(.commandMode))
        let release = d.flags(kcFn, ctrlFlag)
        #expect(release.event == .actionEnded(.commandMode))
        #expect(d.flags(kcCtrl, 0) == (nil, false))
    }

    @Test func spaceDuringCommandHoldAborts() {
        var d = Driver()
        d.fnDown()
        d.flags(kcCtrl, fnFlag | ctrlFlag)
        // Fn+Ctrl+Space matches no binding: ordinary modifier use — abort, pass through.
        let space = d.keyDown(kcSpace, flags: fnFlag | ctrlFlag)
        #expect(space.event == .aborted)
        #expect(!space.swallow)
    }
}

// MARK: - Esc

@Suite struct EscapeTests {
    @Test func escDuringHoldCancelsAndIsSwallowed() {
        var d = Driver()
        d.fnDown()
        let esc = d.keyDown(kcEsc, flags: fnFlag)
        #expect(esc.event == .cancel)
        #expect(esc.swallow)
        #expect(d.keyUp(kcEsc, flags: fnFlag) == (nil, true))
        #expect(!d.machine.isSessionActive)
        // Fn release after the cancel is inert; chord re-arms after all-up.
        #expect(d.fnUp() == (nil, false))
        #expect(d.fnDown().event == .actionBegan(.pushToTalk))
    }

    @Test func escDuringToggleLatchCancels() {
        var d = Driver()
        d.fnDown()
        d.keyDown(kcSpace, flags: fnFlag)
        d.keyUp(kcSpace, flags: fnFlag)
        d.fnUp()
        let esc = d.keyDown(kcEsc)
        #expect(esc.event == .cancel)
        #expect(esc.swallow)
        #expect(d.keyUp(kcEsc) == (nil, true))
        #expect(!d.machine.isSessionActive)
    }

    @Test func escOutsideSessionPassesThrough() {
        var d = Driver()
        #expect(d.keyDown(kcEsc) == (nil, false))
        #expect(d.keyUp(kcEsc) == (nil, false))
    }

    @Test func escAfterSessionEndedPassesThrough() {
        var d = Driver()
        d.fnDown()
        d.fnUp()
        #expect(d.keyDown(kcEsc) == (nil, false))
        #expect(d.keyUp(kcEsc) == (nil, false))
    }

    @Test func externalSessionExtendsEscSwallow() {
        var d = Driver()
        d.machine.externalSessionActive = true
        let esc = d.keyDown(kcEsc)
        #expect(esc.event == .cancel)
        #expect(esc.swallow)
        #expect(d.keyUp(kcEsc) == (nil, true))

        d.machine.externalSessionActive = false
        #expect(d.keyDown(kcEsc) == (nil, false))
    }

    @Test func escAutoRepeatDuringSessionStaysSwallowedWithoutReCancel() {
        var d = Driver()
        d.machine.externalSessionActive = true
        #expect(d.keyDown(kcEsc).event == .cancel)
        let repeated = d.keyDown(kcEsc, isRepeat: true)
        #expect(repeated.event == nil)
        #expect(repeated.swallow)
    }
}

// MARK: - Configuration edge cases

@Suite struct BindingConfigurationTests {
    @Test func unboundActionsNeverFire() {
        var d = Driver(bindings: .init(pushToTalk: nil, toggle: nil, command: nil))
        #expect(d.fnDown() == (nil, false))
        #expect(d.keyDown(kcSpace, flags: fnFlag) == (nil, false))
        #expect(d.fnUp() == (nil, false))
        #expect(!d.machine.isSessionActive)
    }

    @Test func modifierOnlyToggleLatchesOnPressEdges() {
        var b = ChordStateMachine.Bindings.defaults
        b.toggle = ChordBinding(command: true, shift: true) // modifier-only toggle
        var d = Driver(bindings: b)

        var r = d.flags(kcShift, CGEventFlags.maskCommand.rawValue | shiftFlag)
        #expect(r.event == .actionBegan(.toggleDictation))
        // Releasing the chord keeps the latch.
        #expect(d.flags(kcShift, CGEventFlags.maskCommand.rawValue) == (nil, false))
        #expect(d.flags(kcShift, 0) == (nil, false))
        #expect(d.machine.isSessionActive)

        // Pressing it again unlatches.
        #expect(d.flags(kcShift, shiftFlag) == (nil, false))
        r = d.flags(kcShift, CGEventFlags.maskCommand.rawValue | shiftFlag)
        #expect(r.event == .actionEnded(.toggleDictation))
        #expect(!d.machine.isSessionActive)
    }

    @Test func resetClearsTransientState() {
        var d = Driver()
        d.fnDown()
        #expect(d.machine.isSessionActive)
        d.machine.reset()
        #expect(!d.machine.isSessionActive)
        // After reset the (still stale) Fn release is inert.
        #expect(d.fnUp() == (nil, false))
    }

    @Test func externalSessionSurvivesReset() {
        var d = Driver()
        d.machine.externalSessionActive = true
        d.machine.reset()
        #expect(d.machine.isSessionActive)
    }
}
