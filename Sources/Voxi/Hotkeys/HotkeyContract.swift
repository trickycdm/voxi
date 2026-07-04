import Foundation
import CoreGraphics

/// The three global voice actions Voxi binds chords to.
enum VoiceAction: String, Codable, Sendable, CaseIterable {
    case pushToTalk       // hold to dictate, release to insert
    case toggleDictation  // press to start hands-free, press again to stop
    case commandMode      // hold to dictate a task into the queue
}

/// A modifier chord binding (Fn, Ctrl+Opt, Fn+Space, …). KeyboardShortcuts
/// cannot represent modifier-only chords, so Voxi stores these itself.
struct ChordBinding: Codable, Equatable, Sendable {
    /// Required modifier flags, compared device-independently.
    /// Fn is represented by `includesFn` because .maskSecondaryFn is unreliable alone.
    var control: Bool = false
    var option: Bool = false
    var command: Bool = false
    var shift: Bool = false
    var includesFn: Bool = false
    /// Optional regular key that must be pressed while the modifiers are held
    /// (e.g. Space in Fn+Space). CGKeyCode; nil = modifier-only chord.
    var keyCode: UInt16? = nil

    static let defaultPushToTalk = ChordBinding(includesFn: true)
    static let defaultToggle = ChordBinding(includesFn: true, keyCode: 49) // Fn+Space
    static let defaultCommand = ChordBinding(control: true, includesFn: true) // Fn+Ctrl

    var isModifierOnly: Bool { keyCode == nil }
    var hasAnyModifier: Bool { control || option || command || shift || includesFn }
}

/// Events emitted by the hotkey layer toward the dictation controller.
enum HotkeyEvent: Sendable {
    case actionBegan(VoiceAction)   // chord pressed (hold started / toggle latched on)
    case actionEnded(VoiceAction)   // chord released (hold ended / toggle latched off)
    case cancel                     // Esc during an active session
    case aborted                    // chord turned out to be a normal modifier use
}
