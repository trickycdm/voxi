import Foundation

/// A keyboard event abstracted away from NSEvent so chord-recorder capture
/// logic is pure and unit-testable (HubChordCaptureTests).
struct ChordCaptureEvent: Sendable, Equatable {
    enum Kind: Sendable {
        case flagsChanged
        case keyDown
    }

    var kind: Kind
    var keyCode: UInt16
    var control = false
    var option = false
    var command = false
    var shift = false
    /// NSEvent's `.function` flag. Only trusted on flagsChanged with
    /// keyCode 63 — the flag is also set for arrows/F-keys without physical Fn.
    var fnFlag = false
}

extension ChordBinding {
    /// Number of modifier keys the chord requires (Hub recorder helper).
    var hubModifierCount: Int {
        [control, option, command, shift, includesFn].filter { $0 }.count
    }
}

/// Pure state machine behind the Settings chord recorder.
///
/// Semantics:
/// - flagsChanged events track the currently-held modifier set. Physical Fn is
///   only recognized via keyCode 63 (`.function` alone is unreliable).
/// - A keyDown while modifiers are held captures modifiers+key (e.g. Fn+Space).
/// - Releasing any modifier captures the set as held just before the release
///   (modifier-only chords like Fn or ⌃⌥).
/// - Esc cancels; bare keys without modifiers are ignored.
struct ChordCaptureState: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Still recording; associated value is the live held-chord preview.
        case inProgress(ChordBinding)
        case captured(ChordBinding)
        case cancelled
    }

    static let escKeyCode: UInt16 = 53
    static let fnKeyCode: UInt16 = 63

    private(set) var held = ChordBinding()

    mutating func handle(_ event: ChordCaptureEvent) -> Outcome {
        switch event.kind {
        case .keyDown:
            if event.keyCode == Self.escKeyCode { return .cancelled }
            guard held.hasAnyModifier else { return .inProgress(held) }
            var chord = held
            chord.keyCode = event.keyCode
            return .captured(chord)

        case .flagsChanged:
            var next = held
            next.control = event.control
            next.option = event.option
            next.command = event.command
            next.shift = event.shift
            if event.keyCode == Self.fnKeyCode {
                next.includesFn = event.fnFlag
            }
            // Release edge: commit the chord as it was before the release.
            if next.hubModifierCount < held.hubModifierCount, held.hasAnyModifier {
                return .captured(held)
            }
            held = next
            return .inProgress(held)
        }
    }
}
