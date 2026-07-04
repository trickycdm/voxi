import AppKit
import Foundation
import Observation

/// Single source of truth for the pill. Owns exactly one PillPanel for the
/// app's lifetime (created lazily, never closed) and funnels every visibility
/// change through PillTimingPolicy directives, so the pill can never be
/// stranded visible, stuck processing, or double-created.
@MainActor
@Observable
final class PillController {
    private(set) var state: PillState = .idle

    /// Live input level 0...1 for the waveform; AppState feeds this ~30 Hz
    /// from AudioCapture.onLevel. Kept separate from `state` so level ticks
    /// don't re-run show/hide logic.
    var level: Float = 0

    /// Wired by AppState: pill's ✕ button — discard the current dictation.
    var onCancel: (() -> Void)?
    /// Wired by AppState: pill's ✓ button — finish the current dictation.
    var onDone: (() -> Void)?

    private let policy: PillTimingPolicy
    private var panel: PillPanel?
    private var stateTimer: Timer?
    private var hideTimer: Timer?
    private var screenObserver: (any NSObjectProtocol)?

    init(policy: PillTimingPolicy = PillTimingPolicy()) {
        self.policy = policy
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionIfVisible() }
        }
    }

    /// The only way the pill's state changes. Applies the policy directive
    /// (panel visibility + timers) atomically with the state change.
    func transition(to newState: PillState) {
        if PillTimingPolicy.isLevelOnlyChange(from: state, to: newState) {
            if case .recording(_, let newLevel) = newState { level = newLevel }
            state = newState
            return
        }
        let directive = policy.directive(from: state, to: newState)
        state = newState
        apply(directive)
    }

    // MARK: Convenience API for AppState

    func showRecording(_ mode: PillState.RecordingMode) {
        transition(to: .recording(mode: mode, level: level))
    }

    func showProcessing() {
        transition(to: .processing)
    }

    func showNotice(_ message: String) {
        transition(to: .notice(message))
    }

    /// Session over: pill lingers briefly, then hides.
    func finishSession() {
        transition(to: .idle)
    }

    // MARK: Directive execution

    private func apply(_ directive: PillTimingPolicy.Directive) {
        switch directive.timer {
        case .cancel:
            stateTimer?.invalidate()
            stateTimer = nil
        case .arm(let action):
            armStateTimer(action)
        case .keep:
            break
        }

        switch directive.panel {
        case .show:
            hideTimer?.invalidate()
            hideTimer = nil
            showPanel()
        case .scheduleHide(let delay):
            armHideTimer(after: delay)
        case .leaveAsIs:
            break
        }
    }

    private func armStateTimer(_ action: PillTimingPolicy.TimerAction) {
        stateTimer?.invalidate()
        let event: PillTimingPolicy.TimerEvent
        let delay: TimeInterval
        switch action {
        case .dismissNotice(let after):
            event = .noticeDismissElapsed
            delay = after
        case .watchdog(let after):
            event = .watchdogElapsed
            delay = after
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // Scheduled on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated { self?.stateTimerFired(event) }
        }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    private func stateTimerFired(_ event: PillTimingPolicy.TimerEvent) {
        stateTimer = nil
        guard let next = policy.stateAfterTimer(event, current: state) else { return }
        if event == .watchdogElapsed {
            voxiLog.warning("pill: processing watchdog fired after \(self.policy.processingTimeout, privacy: .public)s")
        }
        transition(to: next)
    }

    private func armHideTimer(after delay: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func hideTimerFired() {
        hideTimer = nil
        guard case .idle = state else { return }   // a new session started; stay up
        panel?.orderOut(nil)                       // never close()
    }

    // MARK: Panel

    private func showPanel() {
        let panel = ensurePanel()
        panel.positionBottomCenter()
        // Works while our app is inactive; makeKeyAndOrderFront would try to
        // grab key status and can steal focus from the target app.
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> PillPanel {
        if let panel { return panel }
        let created = PillPanel(content: PillView(controller: self))
        panel = created
        return created
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.positionBottomCenter()
    }
}
