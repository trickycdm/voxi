import Foundation
import Testing
@testable import Voxi

@Suite("Pill timing policy — transition directives")
struct PillTransitionDirectiveTests {
    let policy = PillTimingPolicy()

    @Test("idle → recording shows the panel and cancels timers")
    func idleToRecording() {
        let d = policy.directive(from: .idle, to: .recording(mode: .dictation, level: 0))
        #expect(d == .init(panel: .show, timer: .cancel))
    }

    @Test("recording → processing shows and arms the watchdog")
    func recordingToProcessing() {
        let d = policy.directive(from: .recording(mode: .dictation, level: 0.4), to: .processing)
        #expect(d == .init(panel: .show, timer: .arm(.watchdog(after: 15))))
    }

    @Test("processing → notice shows and arms auto-dismiss")
    func processingToNotice() {
        let d = policy.directive(from: .processing, to: .notice("Mic level too low"))
        #expect(d == .init(panel: .show, timer: .arm(.dismissNotice(after: 2.5))))
    }

    @Test("any non-idle → idle lingers before hiding and cancels the state timer")
    func sessionEndLingers() {
        for from: PillState in [
            .recording(mode: .dictation, level: 0.2),
            .recording(mode: .command, level: 0.9),
            .processing,
            .notice("oops"),
        ] {
            let d = policy.directive(from: from, to: .idle)
            #expect(d == .init(panel: .scheduleHide(after: 1.5), timer: .cancel))
        }
    }

    @Test("idle → idle is a no-op: pending hide keeps running")
    func idleToIdle() {
        let d = policy.directive(from: .idle, to: .idle)
        #expect(d == .init(panel: .leaveAsIs, timer: .keep))
    }

    @Test("processing → processing keeps the original watchdog deadline")
    func processingRepeatKeepsWatchdog() {
        let d = policy.directive(from: .processing, to: .processing)
        #expect(d == .init(panel: .leaveAsIs, timer: .keep))
    }

    @Test("notice → same notice keeps the running dismiss timer")
    func sameNoticeKeepsTimer() {
        let d = policy.directive(from: .notice("a"), to: .notice("a"))
        #expect(d == .init(panel: .leaveAsIs, timer: .keep))
    }

    @Test("notice → different notice re-arms auto-dismiss")
    func newNoticeRearmsTimer() {
        let d = policy.directive(from: .notice("a"), to: .notice("b"))
        #expect(d == .init(panel: .show, timer: .arm(.dismissNotice(after: 2.5))))
    }

    @Test("notice → recording cancels the dismiss timer (new session wins)")
    func noticeInterruptedByRecording() {
        let d = policy.directive(from: .notice("a"), to: .recording(mode: .command, level: 0))
        #expect(d == .init(panel: .show, timer: .cancel))
    }

    @Test("recording mode switch shows again (no timers)")
    func recordingModeSwitch() {
        let d = policy.directive(
            from: .recording(mode: .dictation, level: 0.5),
            to: .recording(mode: .command, level: 0.5))
        #expect(d == .init(panel: .show, timer: .cancel))
    }

    @Test("custom delays flow through directives")
    func customDelays() {
        let custom = PillTimingPolicy(noticeDismissDelay: 1, processingTimeout: 5, idleLinger: 0.5)
        #expect(custom.directive(from: .idle, to: .processing).timer == .arm(.watchdog(after: 5)))
        #expect(custom.directive(from: .idle, to: .notice("x")).timer == .arm(.dismissNotice(after: 1)))
        #expect(custom.directive(from: .processing, to: .idle).panel == .scheduleHide(after: 0.5))
    }
}

@Suite("Pill timing policy — timer resolution")
struct PillTimerResolutionTests {
    let policy = PillTimingPolicy()

    @Test("notice dismiss fires while notice is showing → idle")
    func noticeDismissWhileNotice() {
        #expect(policy.stateAfterTimer(.noticeDismissElapsed, current: .notice("x")) == .idle)
    }

    @Test("stale notice dismiss is a no-op after the state moved on")
    func staleNoticeDismiss() {
        #expect(policy.stateAfterTimer(.noticeDismissElapsed, current: .recording(mode: .dictation, level: 0)) == nil)
        #expect(policy.stateAfterTimer(.noticeDismissElapsed, current: .processing) == nil)
        #expect(policy.stateAfterTimer(.noticeDismissElapsed, current: .idle) == nil)
    }

    @Test("watchdog fires while still processing → timed-out notice")
    func watchdogWhileProcessing() {
        #expect(policy.stateAfterTimer(.watchdogElapsed, current: .processing)
            == .notice(PillTimingPolicy.timedOutMessage))
    }

    @Test("stale watchdog is a no-op after the state moved on")
    func staleWatchdog() {
        #expect(policy.stateAfterTimer(.watchdogElapsed, current: .idle) == nil)
        #expect(policy.stateAfterTimer(.watchdogElapsed, current: .notice("done")) == nil)
        #expect(policy.stateAfterTimer(.watchdogElapsed, current: .recording(mode: .command, level: 0.1)) == nil)
    }
}

@Suite("Pill timing policy — level-only updates")
struct PillLevelOnlyChangeTests {
    @Test("same recording mode, new level → level-only")
    func sameModeIsLevelOnly() {
        #expect(PillTimingPolicy.isLevelOnlyChange(
            from: .recording(mode: .dictation, level: 0.1),
            to: .recording(mode: .dictation, level: 0.8)))
        #expect(PillTimingPolicy.isLevelOnlyChange(
            from: .recording(mode: .command, level: 0.3),
            to: .recording(mode: .command, level: 0.3)))
    }

    @Test("mode switch or case change is never level-only")
    func otherChangesAreNot() {
        #expect(!PillTimingPolicy.isLevelOnlyChange(
            from: .recording(mode: .dictation, level: 0.1),
            to: .recording(mode: .command, level: 0.1)))
        #expect(!PillTimingPolicy.isLevelOnlyChange(from: .idle, to: .recording(mode: .dictation, level: 0)))
        #expect(!PillTimingPolicy.isLevelOnlyChange(from: .recording(mode: .dictation, level: 0.5), to: .processing))
        #expect(!PillTimingPolicy.isLevelOnlyChange(from: .processing, to: .processing))
        #expect(!PillTimingPolicy.isLevelOnlyChange(from: .idle, to: .idle))
    }
}

@Suite("Pill timing policy — recording start (device label)")
struct PillRecordingStartTests {
    @Test("entering recording from any non-recording state is a start")
    func nonRecordingToRecordingIsStart() {
        for from: PillState in [.idle, .processing, .notice("oops")] {
            #expect(PillTimingPolicy.isRecordingStart(
                from: from, to: .recording(mode: .dictation, level: 0)))
            #expect(PillTimingPolicy.isRecordingStart(
                from: from, to: .recording(mode: .command, level: 0)))
        }
    }

    @Test("mid-session retarget and level ticks are not starts")
    func withinRecordingIsNotStart() {
        #expect(!PillTimingPolicy.isRecordingStart(
            from: .recording(mode: .dictation, level: 0.2),
            to: .recording(mode: .command, level: 0.2)))
        #expect(!PillTimingPolicy.isRecordingStart(
            from: .recording(mode: .dictation, level: 0.1),
            to: .recording(mode: .dictation, level: 0.9)))
    }

    @Test("leaving recording is not a start")
    func leavingRecordingIsNotStart() {
        for to: PillState in [.idle, .processing, .notice("oops")] {
            #expect(!PillTimingPolicy.isRecordingStart(
                from: .recording(mode: .dictation, level: 0.4), to: to))
        }
    }
}

/// Drives the policy the way PillController does — one state, one state timer,
/// one pending-hide flag — to prove full sequences can never strand the pill.
private struct PolicyHarness {
    let policy = PillTimingPolicy()
    var state: PillState = .idle
    var armedTimer: PillTimingPolicy.TimerAction?
    var panelVisible = false
    var hidePending = false

    mutating func transition(to new: PillState) {
        if PillTimingPolicy.isLevelOnlyChange(from: state, to: new) {
            state = new
            return
        }
        let d = policy.directive(from: state, to: new)
        state = new
        switch d.timer {
        case .cancel: armedTimer = nil
        case .arm(let action): armedTimer = action
        case .keep: break
        }
        switch d.panel {
        case .show:
            hidePending = false
            panelVisible = true
        case .scheduleHide:
            hidePending = true
        case .leaveAsIs:
            break
        }
    }

    mutating func fireStateTimer() {
        guard let armed = armedTimer else { return }
        armedTimer = nil
        let event: PillTimingPolicy.TimerEvent = switch armed {
        case .dismissNotice: .noticeDismissElapsed
        case .watchdog: .watchdogElapsed
        }
        if let next = policy.stateAfterTimer(event, current: state) {
            transition(to: next)
        }
    }

    mutating func fireHideTimer() {
        guard hidePending else { return }
        hidePending = false
        if case .idle = state { panelVisible = false }
    }
}

@Suite("Pill timing policy — end-to-end sequences")
struct PillSequenceTests {
    @Test("happy path: record → process → idle → hidden")
    func happyPath() {
        var h = PolicyHarness()
        h.transition(to: .recording(mode: .dictation, level: 0))
        #expect(h.panelVisible && h.armedTimer == nil)
        h.transition(to: .processing)
        #expect(h.armedTimer == .watchdog(after: 15))
        h.transition(to: .idle)
        #expect(h.armedTimer == nil && h.hidePending && h.panelVisible)
        h.fireHideTimer()
        #expect(!h.panelVisible)
    }

    @Test("stuck processing: watchdog → timed-out notice → dismiss → hidden")
    func watchdogChainNeverStrands() {
        var h = PolicyHarness()
        h.transition(to: .recording(mode: .command, level: 0.5))
        h.transition(to: .processing)
        h.fireStateTimer()   // watchdog
        #expect(h.state == .notice(PillTimingPolicy.timedOutMessage))
        #expect(h.armedTimer == .dismissNotice(after: 2.5))
        h.fireStateTimer()   // auto-dismiss
        #expect(h.state == .idle && h.hidePending)
        h.fireHideTimer()
        #expect(!h.panelVisible && h.armedTimer == nil)
    }

    @Test("new session during idle linger keeps the panel up")
    func newSessionCancelsPendingHide() {
        var h = PolicyHarness()
        h.transition(to: .recording(mode: .dictation, level: 0.2))
        h.transition(to: .idle)
        #expect(h.hidePending)
        h.transition(to: .recording(mode: .dictation, level: 0))
        #expect(!h.hidePending && h.panelVisible)
        // A hide timer that already fired in flight must be a no-op now.
        h.fireHideTimer()
        #expect(h.panelVisible)
    }

    @Test("rapid show/hide cycling always converges to hidden")
    func rapidCycling() {
        var h = PolicyHarness()
        for _ in 0..<10 {
            h.transition(to: .recording(mode: .dictation, level: 0.7))
            h.transition(to: .processing)
            h.transition(to: .idle)
        }
        #expect(h.armedTimer == nil && h.hidePending)
        h.fireHideTimer()
        #expect(!h.panelVisible)
    }

    @Test("30 Hz level updates during recording change nothing but the level")
    func levelUpdatesAreInert() {
        var h = PolicyHarness()
        h.transition(to: .recording(mode: .dictation, level: 0))
        let before = (h.panelVisible, h.hidePending, h.armedTimer)
        for i in 0..<90 {
            h.transition(to: .recording(mode: .dictation, level: Float(i) / 90))
        }
        #expect(h.panelVisible == before.0 && h.hidePending == before.1 && h.armedTimer == before.2)
        #expect(h.state == .recording(mode: .dictation, level: Float(89) / 90))
    }

    @Test("cancel mid-recording: recording → idle → hidden")
    func cancelMidRecording() {
        var h = PolicyHarness()
        h.transition(to: .recording(mode: .dictation, level: 0.6))
        h.transition(to: .idle)
        h.fireHideTimer()
        #expect(!h.panelVisible && h.state == .idle && h.armedTimer == nil)
    }
}
