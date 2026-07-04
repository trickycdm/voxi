import ApplicationServices
import Foundation
import Observation

/// Public face of the hotkey layer. Owns the ModifierChordTap, persists the
/// three chord bindings in UserDefaults, polls Accessibility trust (there is no
/// grant notification) to build/tear the tap, and forwards HotkeyEvents to
/// AppState via an AsyncStream and/or a handler closure.
@MainActor
@Observable
final class HotkeyController {
    enum PermissionStatus: Equatable, Sendable {
        case unknown            // not started
        case waitingForTrust    // AXIsProcessTrusted() == false — tap not built
        case active             // trusted and tap running
        case tapFailed          // trusted but tap creation failed (unexpected)
    }

    private(set) var permissionStatus: PermissionStatus = .unknown

    var pushToTalkBinding: ChordBinding {
        didSet { store(pushToTalkBinding, key: Keys.pushToTalk); pushBindings() }
    }
    var toggleBinding: ChordBinding {
        didSet { store(toggleBinding, key: Keys.toggle); pushBindings() }
    }
    var commandBinding: ChordBinding {
        didSet { store(commandBinding, key: Keys.command); pushBindings() }
    }

    /// Hotkey events in arrival order. Single consumer (AppState).
    let events: AsyncStream<HotkeyEvent>
    /// Optional synchronous delivery, fired in addition to `events`.
    var eventHandler: ((HotkeyEvent) -> Void)?

    /// Mirror of the app-level session state (recording/processing) so the tap
    /// swallows Esc for the whole session, not just while a chord is down.
    var sessionActive: Bool {
        get { tap.externalSessionActive }
        set { tap.externalSessionActive = newValue }
    }

    private let defaults: UserDefaults
    private let tap: ModifierChordTap
    private let eventContinuation: AsyncStream<HotkeyEvent>.Continuation
    private var pollTimer: Timer?

    private enum Keys {
        static let pushToTalk = "hotkey.binding.pushToTalk"
        static let toggle = "hotkey.binding.toggle"
        static let command = "hotkey.binding.command"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let ptt = Self.loadBinding(key: Keys.pushToTalk, defaults: defaults) ?? .defaultPushToTalk
        let toggle = Self.loadBinding(key: Keys.toggle, defaults: defaults) ?? .defaultToggle
        let command = Self.loadBinding(key: Keys.command, defaults: defaults) ?? .defaultCommand
        pushToTalkBinding = ptt
        toggleBinding = toggle
        commandBinding = command
        tap = ModifierChordTap(machine: ChordStateMachine(
            bindings: .init(pushToTalk: ptt, toggle: toggle, command: command)
        ))
        (events, eventContinuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        tap.onEvent = { [weak self, eventContinuation] event in
            eventContinuation.yield(event)
            self?.eventHandler?(event)
        }
    }

    /// Begins the 1s AXIsProcessTrusted() poll; the tap is built the moment
    /// trust flips on and torn down when it flips off.
    func start() {
        guard pollTimer == nil else { return }
        refreshTrust()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated { self?.refreshTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tap.stop()
        eventContinuation.finish()
        permissionStatus = .unknown
    }

    /// Ends any keyboard-side session state (active hold or toggle latch).
    /// Call when a session is finished/cancelled from the UI rather than the
    /// keyboard, so a stale toggle latch doesn't keep swallowing Esc.
    func resetChordState() {
        tap.resetChordState()
    }

    /// Shows the system Accessibility prompt (once per TCC lifetime).
    func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt is imported as a mutable global (not
        // concurrency-safe under Swift 6); its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func refreshTrust() {
        if AXIsProcessTrusted() {
            permissionStatus = tap.start() ? .active : .tapFailed
        } else {
            tap.stop()
            permissionStatus = .waitingForTrust
        }
    }

    private func pushBindings() {
        tap.updateBindings(.init(
            pushToTalk: pushToTalkBinding,
            toggle: toggleBinding,
            command: commandBinding
        ))
    }

    // MARK: Binding persistence

    private func store(_ binding: ChordBinding, key: String) {
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadBinding(key: String, defaults: UserDefaults) -> ChordBinding? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ChordBinding.self, from: data)
    }

    // MARK: System globe-key action

    /// com.apple.HIToolbox AppleFnUsageType: 0 = Do Nothing, 1 = Change Input
    /// Source, 2 = Show Emoji & Symbols, 3 = Start Dictation. nil = unset
    /// (system default behaves like 1). This action fires on Fn press
    /// independently of our tap and cannot be suppressed by swallowing, so
    /// onboarding should warn unless it is 0.
    nonisolated static func appleFnUsageType() -> Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }

    /// True when pressing Fn will also trigger a system action (input-source
    /// switcher, emoji picker, …) alongside push-to-talk.
    nonisolated static var fnKeyTriggersSystemAction: Bool {
        (appleFnUsageType() ?? 1) != 0
    }

    /// Deep link to System Settings → Privacy & Security → Accessibility.
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// Deep link to System Settings → Keyboard (globe-key action lives here).
    static let keyboardSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
