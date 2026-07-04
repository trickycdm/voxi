import CoreGraphics
import Foundation

// MARK: - Input abstraction

/// Key codes (kVK_*) the chord layer gives special meaning to.
enum ChordKeyCode {
    /// Physical Fn/Globe. Emits no keyDown/keyUp — only flagsChanged with this code.
    static let fn: UInt16 = 63
    static let escape: UInt16 = 53
    static let space: UInt16 = 49
}

/// The three CGEventTap event types the chord layer consumes.
enum ChordEventKind: Sendable, Equatable {
    case flagsChanged
    case keyDown
    case keyUp

    init?(_ type: CGEventType) {
        switch type {
        case .flagsChanged: self = .flagsChanged
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyUp
        default: return nil
        }
    }
}

/// Device-independent modifier set. Only the high (device-independent) CGEventFlags
/// bits are consulted, so left/right modifier variants compare equal.
struct ChordModifiers: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let control = ChordModifiers(rawValue: 1 << 0)
    static let option = ChordModifiers(rawValue: 1 << 1)
    static let command = ChordModifiers(rawValue: 1 << 2)
    static let shift = ChordModifiers(rawValue: 1 << 3)
    static let fn = ChordModifiers(rawValue: 1 << 4)
}

extension ChordBinding {
    var chordModifiers: ChordModifiers {
        var m: ChordModifiers = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if includesFn { m.insert(.fn) }
        return m
    }
}

extension HotkeyEvent: Equatable {
    static func == (lhs: HotkeyEvent, rhs: HotkeyEvent) -> Bool {
        switch (lhs, rhs) {
        case (.cancel, .cancel), (.aborted, .aborted):
            true
        case let (.actionBegan(a), .actionBegan(b)):
            a == b
        case let (.actionEnded(a), .actionEnded(b)):
            a == b
        default:
            false
        }
    }
}

// MARK: - State machine

/// Pure chord-recognition logic, one keyboard event in → at most one HotkeyEvent
/// plus a swallow decision out. No allocation on the hot path; the CGEventTap
/// callback calls `handle` for every keyboard event system-wide.
///
/// Semantics AppState must honor:
/// - `.actionBegan(X)` while a capture is already running (from an earlier
///   `.actionBegan(Y)`) retargets the running session to X. This happens when a
///   held Fn chord upgrades to Fn+Ctrl (command), or Fn+Space converts a
///   tentative push-to-talk hold into the toggle latch — audio keeps flowing.
/// - `.aborted` means the chord turned out to be ordinary modifier use
///   (e.g. Fn+arrow): discard the capture buffer silently.
struct ChordStateMachine: Sendable {
    struct Bindings: Sendable, Equatable {
        var pushToTalk: ChordBinding?
        var toggle: ChordBinding?
        var command: ChordBinding?

        static let defaults = Bindings(
            pushToTalk: .defaultPushToTalk,
            toggle: .defaultToggle,
            command: .defaultCommand
        )
    }

    var bindings: Bindings

    /// Set by the owner when a dictation session is alive beyond what the chords
    /// alone imply (e.g. while transcribing); extends the Esc-swallow window.
    var externalSessionActive = false

    /// Current physical modifier state. Fn is tracked from keyCode-63 flagsChanged
    /// edges because .maskSecondaryFn also appears on arrow/F-key events.
    private var modifiers: ChordModifiers = []
    /// The hold-chord action currently engaged (press seen, release pending).
    private var activeHold: VoiceAction?
    private var activeHoldModifiers: ChordModifiers = []
    private var toggleLatched = false
    /// After a session ends/aborts with modifiers still down, ignore chords until
    /// everything is released — stops Fn+Ctrl release order from re-arming Fn PTT.
    private var needsAllUp = false
    /// keyDowns we swallowed whose matching keyUps must be swallowed too
    /// (fixed slots — at most Esc + the toggle key can be in flight).
    private var swallowKeyUpA: UInt16?
    private var swallowKeyUpB: UInt16?

    init(bindings: Bindings = .defaults) {
        self.bindings = bindings
    }

    var isSessionActive: Bool { activeHold != nil || toggleLatched || externalSessionActive }

    /// Clears transient chord state (bindings and external session flag survive).
    /// Call when the tap is torn down or bindings change.
    mutating func reset() {
        modifiers = []
        activeHold = nil
        activeHoldModifiers = []
        toggleLatched = false
        needsAllUp = false
        swallowKeyUpA = nil
        swallowKeyUpB = nil
    }

    /// Feed one keyboard event. `flags` is CGEventFlags.rawValue; `swallow: true`
    /// means the tap callback must return nil so the event never reaches the app.
    mutating func handle(
        kind: ChordEventKind,
        keyCode: UInt16,
        flags: UInt64,
        isRepeat: Bool = false
    ) -> (event: HotkeyEvent?, swallow: Bool) {
        switch kind {
        case .flagsChanged: handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown: handleKeyDown(keyCode: keyCode, isRepeat: isRepeat)
        case .keyUp: handleKeyUp(keyCode: keyCode)
        }
    }

    // MARK: flagsChanged

    private mutating func handleFlagsChanged(keyCode: UInt16, flags: UInt64) -> (HotkeyEvent?, Bool) {
        let f = CGEventFlags(rawValue: flags)
        var m: ChordModifiers = []
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        // Fn down is only trusted on its own event (keyCode 63); once down it is
        // kept while other modifier events still carry the flag. A missing flag
        // always clears it, self-healing any missed release.
        if f.contains(.maskSecondaryFn), keyCode == ChordKeyCode.fn || modifiers.contains(.fn) {
            m.insert(.fn)
        }
        guard m != modifiers else { return (nil, false) } // e.g. caps lock
        modifiers = m
        // flagsChanged is never swallowed: suppressing it is unreliable (the
        // system globe action fires regardless) and starves apps of state.
        return (chordTransition(), false)
    }

    private mutating func chordTransition() -> HotkeyEvent? {
        let m = modifiers
        if needsAllUp {
            if m.isEmpty { needsAllUp = false }
            return nil
        }
        if let action = activeHold {
            if m == activeHoldModifiers { return nil }
            if m.isSuperset(of: activeHoldModifiers) {
                // Extra modifier on top of the held chord: upgrade when the new
                // set is exactly another modifier-only binding (Fn → Fn+Ctrl);
                // otherwise keep holding — a bound keyDown may still follow.
                if let (newAction, newMods) = modifierOnlyMatch(m), newAction != action {
                    activeHold = newAction
                    activeHoldModifiers = newMods
                    return .actionBegan(newAction)
                }
                return nil
            }
            // A required modifier came up: release-to-commit.
            activeHold = nil
            activeHoldModifiers = []
            needsAllUp = !m.isEmpty
            return .actionEnded(action)
        }
        if toggleLatched {
            // While latched, only a modifier-only toggle chord can act (unlatch);
            // the default Fn+Space unlatches via keyDown instead.
            if let t = bindings.toggle, t.isModifierOnly, t.hasAnyModifier, m == t.chordModifiers {
                toggleLatched = false
                needsAllUp = true
                return .actionEnded(.toggleDictation)
            }
            return nil
        }
        guard let (action, mods) = modifierOnlyMatch(m) else { return nil }
        if action == .toggleDictation {
            toggleLatched = true
            needsAllUp = true
            return .actionBegan(.toggleDictation)
        }
        activeHold = action
        activeHoldModifiers = mods
        return .actionBegan(action)
    }

    /// Exact (equality) match of the current modifier set against the
    /// modifier-only bindings. Exactness makes matching order-independent and
    /// unambiguous unless the user binds two actions to the same chord.
    private func modifierOnlyMatch(_ m: ChordModifiers) -> (VoiceAction, ChordModifiers)? {
        guard !m.isEmpty else { return nil }
        if let b = bindings.pushToTalk, b.isModifierOnly, m == b.chordModifiers {
            return (.pushToTalk, m)
        }
        if let b = bindings.command, b.isModifierOnly, m == b.chordModifiers {
            return (.commandMode, m)
        }
        if let b = bindings.toggle, b.isModifierOnly, m == b.chordModifiers {
            return (.toggleDictation, m)
        }
        return nil
    }

    // MARK: keyDown / keyUp

    private mutating func handleKeyDown(keyCode: UInt16, isRepeat: Bool) -> (HotkeyEvent?, Bool) {
        let matchesToggleKey = bindings.toggle.map {
            $0.keyCode == keyCode && modifiers == $0.chordModifiers
        } ?? false

        if isRepeat {
            // Auto-repeat must not flap the latch or re-cancel, but keys we are
            // swallowing must stay swallowed.
            if matchesToggleKey { return (nil, true) }
            if keyCode == ChordKeyCode.escape, isSessionActive { return (nil, true) }
            return (nil, false)
        }

        if matchesToggleKey {
            rememberKeyUpSwallow(keyCode)
            if toggleLatched {
                toggleLatched = false
                needsAllUp = !modifiers.isEmpty
                return (.actionEnded(.toggleDictation), true)
            }
            // Converts a tentative hold (Fn already began PTT) into the latch.
            activeHold = nil
            activeHoldModifiers = []
            toggleLatched = true
            return (.actionBegan(.toggleDictation), true)
        }

        if keyCode == ChordKeyCode.escape, isSessionActive {
            rememberKeyUpSwallow(keyCode)
            activeHold = nil
            activeHoldModifiers = []
            toggleLatched = false
            needsAllUp = !modifiers.isEmpty
            return (.cancel, true)
        }

        if activeHold != nil {
            // Unbound key while the chord is held: the user is using the
            // modifiers normally (Fn+arrow, Ctrl+Opt+letter) — abort the session
            // and pass the key through untouched.
            activeHold = nil
            activeHoldModifiers = []
            needsAllUp = true
            return (.aborted, false)
        }

        return (nil, false)
    }

    private mutating func handleKeyUp(keyCode: UInt16) -> (HotkeyEvent?, Bool) {
        if swallowKeyUpA == keyCode {
            swallowKeyUpA = nil
            return (nil, true)
        }
        if swallowKeyUpB == keyCode {
            swallowKeyUpB = nil
            return (nil, true)
        }
        return (nil, false)
    }

    private mutating func rememberKeyUpSwallow(_ keyCode: UInt16) {
        if swallowKeyUpA == nil || swallowKeyUpA == keyCode {
            swallowKeyUpA = keyCode
        } else {
            swallowKeyUpB = keyCode
        }
    }
}
