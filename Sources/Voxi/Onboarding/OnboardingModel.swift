import Foundation
import Observation

/// Microphone authorization distilled to what the onboarding gate needs.
/// (`denied` also covers `.restricted` — both need the Settings deep link.)
enum MicPermissionState: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

/// Pure step/gate logic for the first-run flow. The views feed live inputs
/// (permission states, globe-key flag, mic-test result) into the mutable
/// properties; everything else — which steps exist, which are passable,
/// advance/back rules, and the completion gate — is deterministic and
/// unit-tested without touching any system API.
@MainActor
@Observable
final class OnboardingModel {
    /// All onboarding pages, in presentation order.
    enum Step: Equatable, CaseIterable, Sendable {
        case welcome        // what Voxi is, local-first
        case microphone     // AVCaptureDevice permission
        case accessibility  // AXIsProcessTrusted (event tap)
        case globeKey       // only when the 🌐 key triggers a system action
        case micTest        // live level meter, prove the mic works
        case hotkeys        // summary of the three default chords
    }

    static let completedDefaultsKey = "onboarding.completed"

    /// True until the user has completed onboarding once.
    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedDefaultsKey)
    }

    /// Steps visible for this run. Globe-key visibility is decided once at
    /// init so the page list is stable; the step's *gate* re-checks live
    /// while it is displayed (`fnTriggersSystemAction` flipping false opens
    /// Next without reshuffling pages).
    let steps: [Step]

    // MARK: Live inputs (kept current by the view layer's poll loop)

    var micPermission: MicPermissionState = .undetermined
    var accessibilityGranted = false
    var fnTriggersSystemAction: Bool
    var micTestPassed = false

    // MARK: Navigation state

    private(set) var stepIndex = 0
    private(set) var isFinished = false

    private let defaults: UserDefaults
    /// Fired once on completion; integration uses it to close the window.
    var onFinished: (() -> Void)?

    init(
        fnTriggersSystemAction: Bool = HotkeyController.fnKeyTriggersSystemAction,
        defaults: UserDefaults = .standard
    ) {
        self.fnTriggersSystemAction = fnTriggersSystemAction
        self.defaults = defaults
        self.steps = Self.visibleSteps(fnTriggersSystemAction: fnTriggersSystemAction)
    }

    static func visibleSteps(fnTriggersSystemAction: Bool) -> [Step] {
        Step.allCases.filter { $0 != .globeKey || fnTriggersSystemAction }
    }

    var currentStep: Step { steps[stepIndex] }
    var isLastStep: Bool { stepIndex == steps.count - 1 }
    var canGoBack: Bool { stepIndex > 0 && !isFinished }

    /// Whether a step's gate is currently open (Next enabled). The user can
    /// never proceed past a broken state (missing permission, silent mic,
    /// globe key still bound to a system action).
    func isPassable(_ step: Step) -> Bool {
        switch step {
        case .welcome, .hotkeys: true
        case .microphone: micPermission == .granted
        case .accessibility: accessibilityGranted
        case .globeKey: !fnTriggersSystemAction
        case .micTest: micTestPassed
        }
    }

    var canAdvance: Bool { isPassable(currentStep) && !isFinished }

    func advance() {
        guard canAdvance, !isLastStep else { return }
        stepIndex += 1
    }

    func back() {
        guard canGoBack else { return }
        stepIndex -= 1
    }

    /// Complete onboarding: persist the defaults gate and notify integration.
    /// Only possible from the last step with its gate open.
    func finish() {
        guard isLastStep, canAdvance else { return }
        isFinished = true
        defaults.set(true, forKey: Self.completedDefaultsKey)
        onFinished?()
    }
}

/// Pure pass/fail logic for the mic test, separated for unit testing.
///
/// `AudioCapture.onLevel` emits `AudioLevelMath.normalizedLevel(rms:)` per
/// chunk. A chunk's RMS never exceeds its peak, so any level at/above
/// `normalizedLevel(rms: SignalGuard.peakThreshold)` proves the raw capture
/// peak exceeded `SignalGuard.peakThreshold` — the same threshold the
/// hallucination guard uses to accept a capture as speech.
enum MicTestGate {
    static let successLevel: Float =
        AudioLevelMath.normalizedLevel(rms: SignalGuard.peakThreshold)

    static func passes(peakObservedLevel: Float) -> Bool {
        peakObservedLevel >= successLevel
    }
}
