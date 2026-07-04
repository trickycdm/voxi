import CoreGraphics
import Foundation

/// Owns the active CGEventTap (needs Accessibility) and pumps every keyboard
/// event through the ChordStateMachine. Returning nil from the callback swallows
/// the event system-wide, which is how Fn+Space and Esc are kept out of the
/// frontmost app during a session.
///
/// Main-actor bound: create, start, and stop on the main thread. The tap's run
/// loop source is scheduled on the main run loop, so the C callback always runs
/// there too. The callback path is allocation-free — it sits in the delivery
/// path of every keystroke on the machine.
@MainActor
final class ModifierChordTap {
    enum Status: Equatable, Sendable {
        case stopped
        case running
        /// CGEvent.tapCreate returned nil — Accessibility permission is missing.
        case creationFailed
    }

    private(set) var status: Status = .stopped
    private(set) var machine: ChordStateMachine
    var onEvent: ((HotkeyEvent) -> Void)?

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(machine: ChordStateMachine = ChordStateMachine()) {
        self.machine = machine
    }

    /// Replaces the chord bindings and clears transient chord state.
    func updateBindings(_ bindings: ChordStateMachine.Bindings) {
        machine.bindings = bindings
        machine.reset()
    }

    var externalSessionActive: Bool {
        get { machine.externalSessionActive }
        set { machine.externalSessionActive = newValue }
    }

    /// Clears transient chord state (holds, toggle latch). Needed when a
    /// session is ended from outside the keyboard (pill buttons) so a stale
    /// latch doesn't keep swallowing Esc.
    func resetChordState() {
        machine.reset()
    }

    /// Creates and enables the tap. Returns false (status .creationFailed) when
    /// the process is not Accessibility-trusted. Safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        if tapPort != nil { return true }

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ModifierChordTap>.fromOpaque(refcon).takeUnretainedValue()

                // The system disables a tap whose callback stalls; re-enable or
                // every hotkey dies silently.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { tap.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                guard let kind = ChordEventKind(type) else {
                    return Unmanaged.passUnretained(event)
                }
                // Extract Sendable scalars here; the CGEvent itself never
                // crosses into actor-isolated code.
                let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let swallow = MainActor.assumeIsolated {
                    tap.process(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = .creationFailed
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = source
        status = .running
        return true
    }

    func stop() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tapPort = nil
        runLoopSource = nil
        machine.reset()
        status = .stopped
    }

    private func reenable() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }

    private func process(kind: ChordEventKind, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        let (event, swallow) = machine.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        if let event {
            onEvent?(event)
        }
        return swallow
    }
}
