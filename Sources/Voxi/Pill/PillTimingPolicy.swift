import Foundation

/// Pure timing/transition policy for the pill. Every show/hide/timer decision
/// the controller makes is computed here so it can be unit-tested without
/// AppKit. The controller executes directives; this type only decides.
struct PillTimingPolicy: Equatable, Sendable {
    /// How long a .notice bubble stays before auto-dismissing to .idle.
    var noticeDismissDelay: TimeInterval = 2.5
    /// Watchdog: max time in .processing before force-flipping to a timeout
    /// notice, so the pill can never be stranded spinning.
    var processingTimeout: TimeInterval = 15
    /// After a session ends (any non-idle → .idle), the panel lingers briefly
    /// before hiding.
    var idleLinger: TimeInterval = 1.5

    static let timedOutMessage = "Timed out"

    enum PanelAction: Equatable, Sendable {
        /// Order the panel front now (cancels any pending hide).
        case show
        /// Keep the panel visible, hide it after the delay if still idle.
        case scheduleHide(after: TimeInterval)
        /// Leave panel visibility exactly as it is (pending hides keep running).
        case leaveAsIs
    }

    enum TimerAction: Equatable, Sendable {
        case dismissNotice(after: TimeInterval)
        case watchdog(after: TimeInterval)
    }

    enum TimerDirective: Equatable, Sendable {
        case arm(TimerAction)
        case cancel
        /// Leave the currently armed timer (if any) running.
        case keep
    }

    struct Directive: Equatable, Sendable {
        var panel: PanelAction
        var timer: TimerDirective
    }

    /// Decision for a state transition. Callers must apply the timer directive
    /// to the single state timer and the panel action to panel visibility.
    func directive(from: PillState, to: PillState) -> Directive {
        switch to {
        case .idle:
            if case .idle = from {
                // Nothing happened; do not disturb a pending hide.
                return Directive(panel: .leaveAsIs, timer: .keep)
            }
            return Directive(panel: .scheduleHide(after: idleLinger), timer: .cancel)

        case .recording:
            return Directive(panel: .show, timer: .cancel)

        case .processing:
            if case .processing = from {
                // Already processing: the watchdog must keep its original deadline.
                return Directive(panel: .leaveAsIs, timer: .keep)
            }
            return Directive(panel: .show, timer: .arm(.watchdog(after: processingTimeout)))

        case .notice(let message):
            if case .notice(let old) = from, old == message {
                return Directive(panel: .leaveAsIs, timer: .keep)
            }
            return Directive(panel: .show, timer: .arm(.dismissNotice(after: noticeDismissDelay)))
        }
    }

    enum TimerEvent: Equatable, Sendable {
        case noticeDismissElapsed
        case watchdogElapsed
    }

    /// Where a fired timer takes the state — or nil when the state already
    /// moved on and the fire is stale (must be a no-op).
    func stateAfterTimer(_ event: TimerEvent, current: PillState) -> PillState? {
        switch (event, current) {
        case (.noticeDismissElapsed, .notice):
            return .idle
        case (.watchdogElapsed, .processing):
            return .notice(Self.timedOutMessage)
        default:
            return nil
        }
    }

    /// True when the transition only carries a fresh waveform level within the
    /// same recording mode — the controller updates `level` without re-running
    /// panel/timer directives (level arrives ~30 Hz).
    static func isLevelOnlyChange(from: PillState, to: PillState) -> Bool {
        guard case .recording(let oldMode, _) = from,
              case .recording(let newMode, _) = to else { return false }
        return oldMode == newMode
    }
}
