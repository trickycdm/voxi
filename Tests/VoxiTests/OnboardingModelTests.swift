import Foundation
import Testing
@testable import Voxi

@MainActor
@Suite struct OnboardingModelTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "voxi-onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Model with every gate open, for navigation tests.
    private func allGranted(fnTriggersSystemAction: Bool = false,
                            defaults: UserDefaults? = nil) -> OnboardingModel {
        let model = OnboardingModel(
            fnTriggersSystemAction: fnTriggersSystemAction,
            defaults: defaults ?? scratchDefaults())
        model.micPermission = .granted
        model.accessibilityGranted = true
        model.micTestPassed = true
        model.modelReady = true
        if fnTriggersSystemAction { model.fnTriggersSystemAction = false } // resolved live
        return model
    }

    // MARK: Step visibility

    @Test func globeStepHiddenWhenFnKeyIsFree() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        #expect(model.steps == [.welcome, .microphone, .accessibility, .micTest, .speechModel, .hotkeys])
    }

    @Test func globeStepShownWhenFnKeyTriggersSystemAction() {
        let model = OnboardingModel(fnTriggersSystemAction: true, defaults: scratchDefaults())
        #expect(model.steps == [.welcome, .microphone, .accessibility, .globeKey, .micTest, .speechModel, .hotkeys])
    }

    // MARK: Passability matrix

    @Test func welcomeAndHotkeySummaryAreAlwaysPassable() {
        let model = OnboardingModel(fnTriggersSystemAction: true, defaults: scratchDefaults())
        // Freshly initialized: nothing granted, nothing tested.
        #expect(model.isPassable(.welcome))
        #expect(model.isPassable(.hotkeys))
        #expect(!model.isPassable(.microphone))
        #expect(!model.isPassable(.accessibility))
        #expect(!model.isPassable(.globeKey))
        #expect(!model.isPassable(.micTest))
        #expect(!model.isPassable(.speechModel))
    }

    @Test func microphoneGateFollowsPermissionState() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        model.micPermission = .undetermined
        #expect(!model.isPassable(.microphone))
        model.micPermission = .denied
        #expect(!model.isPassable(.microphone))
        model.micPermission = .granted
        #expect(model.isPassable(.microphone))
    }

    @Test func accessibilityGateFollowsTrust() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        #expect(!model.isPassable(.accessibility))
        model.accessibilityGranted = true
        #expect(model.isPassable(.accessibility))
        model.accessibilityGranted = false // revoked mid-flow
        #expect(!model.isPassable(.accessibility))
    }

    @Test func globeKeyGateOpensWhenSystemActionRemovedLive() {
        let model = OnboardingModel(fnTriggersSystemAction: true, defaults: scratchDefaults())
        #expect(model.steps.contains(.globeKey))
        #expect(!model.isPassable(.globeKey))
        model.fnTriggersSystemAction = false // user set "Do Nothing" in Settings
        #expect(model.isPassable(.globeKey))
        // Step list stays stable even after the live flag flips.
        #expect(model.steps.contains(.globeKey))
    }

    @Test func micTestGateFollowsTestResult() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        #expect(!model.isPassable(.micTest))
        model.micTestPassed = true
        #expect(model.isPassable(.micTest))
    }

    @Test func speechModelGateFollowsModelReady() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        #expect(!model.isPassable(.speechModel))
        model.modelReady = true // pre-existing download or step completed
        #expect(model.isPassable(.speechModel))
    }

    // MARK: Navigation rules

    @Test func advanceBlockedUntilGateOpens() {
        let model = OnboardingModel(fnTriggersSystemAction: false, defaults: scratchDefaults())
        model.advance() // welcome -> microphone
        #expect(model.currentStep == .microphone)
        #expect(!model.canAdvance)
        model.advance() // gate closed: no-op
        #expect(model.currentStep == .microphone)
        model.micPermission = .granted
        #expect(model.canAdvance)
        model.advance()
        #expect(model.currentStep == .accessibility)
    }

    @Test func backWalksToThePreviousStepAndStopsAtWelcome() {
        let model = allGranted()
        #expect(!model.canGoBack)
        model.back() // no-op at the first step
        #expect(model.currentStep == .welcome)
        model.advance()
        model.advance()
        #expect(model.currentStep == .accessibility)
        model.back()
        #expect(model.currentStep == .microphone)
        model.back()
        model.back() // extra back is a no-op
        #expect(model.currentStep == .welcome)
    }

    @Test func advanceStopsAtTheLastStep() {
        let model = allGranted()
        for _ in 0..<20 { model.advance() }
        #expect(model.isLastStep)
        #expect(model.currentStep == .hotkeys)
    }

    // MARK: Completion gate

    @Test func finishIsIgnoredBeforeTheLastStep() {
        let defaults = scratchDefaults()
        let model = allGranted(defaults: defaults)
        model.finish() // still on welcome
        #expect(!model.isFinished)
        #expect(OnboardingModel.shouldShow(defaults: defaults))
    }

    @Test func fullRunThroughAllGatesCompletesAndPersists() {
        let defaults = scratchDefaults()
        #expect(OnboardingModel.shouldShow(defaults: defaults))

        let model = OnboardingModel(fnTriggersSystemAction: true, defaults: defaults)
        var finishedCallbacks = 0
        model.onFinished = { finishedCallbacks += 1 }

        model.advance() // welcome -> microphone
        model.micPermission = .granted
        model.advance() // -> accessibility
        model.accessibilityGranted = true
        model.advance() // -> globeKey
        model.fnTriggersSystemAction = false
        model.advance() // -> micTest
        model.micTestPassed = true
        model.advance() // -> speechModel
        model.modelReady = true
        model.advance() // -> hotkeys
        #expect(model.isLastStep)

        model.finish()
        #expect(model.isFinished)
        #expect(finishedCallbacks == 1)
        #expect(defaults.bool(forKey: OnboardingModel.completedDefaultsKey))
        #expect(!OnboardingModel.shouldShow(defaults: defaults))
        // Finished flow accepts no further navigation.
        #expect(!model.canAdvance)
        #expect(!model.canGoBack)
    }

    @Test func shouldShowRoundTripsThroughTheDefaultsKey() {
        let defaults = scratchDefaults()
        #expect(OnboardingModel.shouldShow(defaults: defaults))
        defaults.set(true, forKey: "onboarding.completed")
        #expect(!OnboardingModel.shouldShow(defaults: defaults))
        defaults.removeObject(forKey: "onboarding.completed")
        #expect(OnboardingModel.shouldShow(defaults: defaults))
    }
}

@Suite struct MicTestGateTests {
    @Test func thresholdDerivesFromSignalGuardPeakThreshold() {
        let expected = AudioLevelMath.normalizedLevel(rms: SignalGuard.peakThreshold)
        #expect(MicTestGate.successLevel == expected)
        // Sanity: the threshold sits inside the meter's visible range.
        #expect(MicTestGate.successLevel > 0.05)
        #expect(MicTestGate.successLevel < 0.9)
    }

    @Test func passesAtOrAboveThresholdOnly() {
        #expect(!MicTestGate.passes(peakObservedLevel: 0))
        #expect(!MicTestGate.passes(peakObservedLevel: MicTestGate.successLevel - 0.001))
        #expect(MicTestGate.passes(peakObservedLevel: MicTestGate.successLevel))
        #expect(MicTestGate.passes(peakObservedLevel: 1))
    }
}

@Suite struct OnboardingChordSymbolsTests {
    @Test func defaultChordsRenderTheExpectedSymbols() {
        #expect(ChordSymbols.parts(for: .defaultPushToTalk) == ["fn"])
        #expect(ChordSymbols.parts(for: .defaultToggle) == ["fn", "Space"])
        #expect(ChordSymbols.parts(for: .defaultCommand) == ["fn", "⌃"])
        #expect(ChordSymbols.label(for: .defaultToggle) == "fn + Space")
    }

    @Test func modifierOrderIsMacOSDisplayOrder() {
        let everything = ChordBinding(
            control: true, option: true, command: true, shift: true,
            includesFn: true, keyCode: 36)
        #expect(ChordSymbols.parts(for: everything) == ["fn", "⌃", "⌥", "⇧", "⌘", "Return"])
    }

    @Test func unknownKeyCodeFallsBackToNumericName() {
        let binding = ChordBinding(control: true, keyCode: 999)
        #expect(ChordSymbols.label(for: binding) == "⌃ + Key 999")
    }
}
