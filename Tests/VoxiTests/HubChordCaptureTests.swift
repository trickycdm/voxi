import Foundation
import Testing
@testable import Voxi

/// Synthetic-event tests for the pure chord-recorder state machine.
@Suite struct HubChordCaptureTests {
    private func flags(
        keyCode: UInt16,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        shift: Bool = false,
        fn: Bool = false
    ) -> ChordCaptureEvent {
        ChordCaptureEvent(
            kind: .flagsChanged, keyCode: keyCode,
            control: control, option: option, command: command, shift: shift, fnFlag: fn
        )
    }

    private func keyDown(_ keyCode: UInt16, fn: Bool = false) -> ChordCaptureEvent {
        ChordCaptureEvent(kind: .keyDown, keyCode: keyCode, fnFlag: fn)
    }

    @Test func fnPressReleaseCapturesModifierOnlyFn() {
        var state = ChordCaptureState()
        #expect(state.handle(flags(keyCode: 63, fn: true)) == .inProgress(ChordBinding(includesFn: true)))
        #expect(state.handle(flags(keyCode: 63, fn: false)) == .captured(ChordBinding(includesFn: true)))
    }

    @Test func ctrlOptReleaseCapturesBothModifiers() {
        var state = ChordCaptureState()
        _ = state.handle(flags(keyCode: 59, control: true))
        _ = state.handle(flags(keyCode: 58, control: true, option: true))
        let outcome = state.handle(flags(keyCode: 58, control: true, option: false))
        #expect(outcome == .captured(ChordBinding(control: true, option: true)))
    }

    @Test func fnPlusSpaceCapturesModifiersAndKey() {
        var state = ChordCaptureState()
        _ = state.handle(flags(keyCode: 63, fn: true))
        let outcome = state.handle(keyDown(49, fn: true)) // Space with fn held
        #expect(outcome == .captured(ChordBinding(includesFn: true, keyCode: 49)))
    }

    @Test func escCancelsEvenWithModifiersHeld() {
        var state = ChordCaptureState()
        _ = state.handle(flags(keyCode: 59, control: true))
        #expect(state.handle(keyDown(53)) == .cancelled)
    }

    @Test func bareKeyWithoutModifiersIsIgnored() {
        var state = ChordCaptureState()
        let outcome = state.handle(keyDown(0)) // A with nothing held
        #expect(outcome == .inProgress(ChordBinding()))
    }

    @Test func fnFlagOnNonFnKeyDoesNotSetFn() {
        var state = ChordCaptureState()
        _ = state.handle(flags(keyCode: 59, control: true))
        // Arrow keys report the .function flag without physical Fn.
        let outcome = state.handle(keyDown(123, fn: true)) // ← with ctrl held
        #expect(outcome == .captured(ChordBinding(control: true, keyCode: 123)))
    }

    @Test func fnStatePreservedThroughOtherFlagChanges() {
        var state = ChordCaptureState()
        _ = state.handle(flags(keyCode: 63, fn: true))
        // Ctrl joins; its flagsChanged carries fnFlag but keyCode != 63, so fn is preserved.
        _ = state.handle(flags(keyCode: 59, control: true, fn: true))
        // Ctrl releases first: commit the pre-release set (Fn+Ctrl).
        let outcome = state.handle(flags(keyCode: 59, control: false, fn: true))
        #expect(outcome == .captured(ChordBinding(control: true, includesFn: true)))
    }

    @Test func growingChordDoesNotCommitUntilRelease() {
        var state = ChordCaptureState()
        #expect(state.handle(flags(keyCode: 56, shift: true))
            == .inProgress(ChordBinding(shift: true)))
        #expect(state.handle(flags(keyCode: 55, command: true, shift: true))
            == .inProgress(ChordBinding(command: true, shift: true)))
    }
}
