import AVFoundation
import AppKit
import SwiftUI

/// First-run flow: welcome → mic permission → accessibility → globe-key fix
/// (when needed) → mic test → hotkey summary. The window scene is wired at
/// integration; this view only needs the shared controllers.
struct OnboardingView: View {
    let model: OnboardingModel
    let hotkeys: HotkeyController
    let capture: AudioCapture
    @Environment(\.dismiss) private var dismiss

    /// Deep link to System Settings → Privacy & Security → Microphone.
    static let microphonePrivacyURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Color.voxiPaper)
        .frame(width: 560, height: 420)
        .task { await pollLiveState() }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.currentStep {
        case .welcome:
            WelcomeStep()
        case .microphone:
            MicrophonePermissionStep(model: model)
        case .accessibility:
            AccessibilityPermissionStep(model: model, hotkeys: hotkeys)
        case .globeKey:
            GlobeKeyStep(model: model)
        case .micTest:
            MicTestStep(model: model, capture: capture)
        case .hotkeys:
            HotkeySummaryStep(hotkeys: hotkeys)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }
                .opacity(model.canGoBack ? 1 : 0)
                .disabled(!model.canGoBack)

            Spacer()
            progressDots
            Spacer()

            if model.isLastStep {
                Button("Done") {
                    model.finish()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdvance)
            } else {
                Button(model.currentStep == .welcome ? "Get Started" : "Next") {
                    model.advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdvance)
            }
        }
        .padding(20)
        .background(Color.voxiCard)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
        }
    }

    /// Gauge ticks, not dots: onboarding is a real sequence, so the tachometer
    /// motif encodes true order — done and current ticks in accent, the
    /// current one taller.
    private var progressDots: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(model.steps.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index <= model.stepIndex
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.voxiHairline))
                    .frame(width: 3, height: index == model.stepIndex ? 14 : 10)
            }
        }
        .accessibilityLabel("Step \(model.stepIndex + 1) of \(model.steps.count)")
    }

    // MARK: Live re-checks

    /// 1 Hz refresh of every gate input while the window is open, so a grant
    /// made in System Settings unlocks Next without any interaction here.
    private func pollLiveState() async {
        hotkeys.start() // idempotent; drives the AXIsProcessTrusted() poll
        while !Task.isCancelled {
            refreshLiveState()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refreshLiveState() {
        model.micPermission = Self.currentMicPermission()
        // .tapFailed still means the permission itself is granted.
        model.accessibilityGranted =
            hotkeys.permissionStatus == .active || hotkeys.permissionStatus == .tapFailed
        model.fnTriggersSystemAction = HotkeyController.fnKeyTriggersSystemAction
    }

    static func currentMicPermission() -> MicPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

// MARK: - Shared step scaffolding

/// Icon + title + body copy layout shared by every step.
private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 52)
            Text(title)
                .font(.title2.bold())
            content
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 48)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Granted/pending status line used by the permission steps.
private struct PermissionStatusRow: View {
    let granted: Bool
    let grantedText: String
    let pendingText: String

    var body: some View {
        Label {
            Text(granted ? grantedText : pendingText)
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? AnyShapeStyle(Color.voxiSuccess) : AnyShapeStyle(.secondary))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(granted ? .primary : .secondary)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        StepLayout(symbol: "mic.fill", title: "Welcome to Voxi") {
            Text("Hold a hotkey, speak, release — polished text appears at the cursor in whatever app you're using.")
                .foregroundStyle(.secondary)
            Text("Voxi is local-first: transcription runs entirely on this Mac. Your voice never leaves it.")
                .font(.callout.weight(.medium))
            Text("A couple of one-time permissions are needed first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Step 2: Microphone permission

private struct MicrophonePermissionStep: View {
    let model: OnboardingModel

    var body: some View {
        StepLayout(symbol: "mic.badge.plus", title: "Microphone Access") {
            Text("Voxi needs the microphone to hear your dictation. Audio is transcribed on-device and never uploaded.")
                .foregroundStyle(.secondary)

            PermissionStatusRow(
                granted: model.micPermission == .granted,
                grantedText: "Microphone access granted",
                pendingText: "Waiting for microphone access…")

            switch model.micPermission {
            case .undetermined:
                Button("Allow Microphone Access") {
                    Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                }
            case .denied:
                VStack(spacing: 6) {
                    Text("Access was denied. Enable Voxi under Privacy & Security → Microphone, then come back — this page re-checks automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Microphone Settings") {
                        NSWorkspace.shared.open(OnboardingView.microphonePrivacyURL)
                    }
                }
            case .granted:
                EmptyView()
            }
        }
    }
}

// MARK: - Step 3: Accessibility permission

private struct AccessibilityPermissionStep: View {
    let model: OnboardingModel
    let hotkeys: HotkeyController

    var body: some View {
        StepLayout(symbol: "accessibility", title: "Accessibility Access") {
            Text("Voxi's global hotkeys (like holding fn to talk) and cursor insertion use the Accessibility API. macOS asks you to grant this once.")
                .foregroundStyle(.secondary)

            PermissionStatusRow(
                granted: model.accessibilityGranted,
                grantedText: "Accessibility access granted",
                pendingText: "Waiting for Accessibility access…")

            if !model.accessibilityGranted {
                VStack(spacing: 6) {
                    Button("Request Accessibility Access") {
                        hotkeys.requestAccessibility()
                    }
                    Text("If no prompt appears, enable Voxi manually — this page re-checks automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(HotkeyController.accessibilitySettingsURL)
                    }
                }
            }
        }
    }
}

// MARK: - Step 4: Globe key (only when it triggers a system action)

private struct GlobeKeyStep: View {
    let model: OnboardingModel

    var body: some View {
        StepLayout(symbol: "globe", title: "Free Up the 🌐 Key") {
            Text("Holding fn (🌐) is Voxi's push-to-talk key, but your Mac currently also triggers a system action (input switcher, emoji picker, or Apple dictation) every time it's pressed.")
                .foregroundStyle(.secondary)
            Text("In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”.")
                .font(.callout.weight(.medium))

            PermissionStatusRow(
                granted: !model.fnTriggersSystemAction,
                grantedText: "The 🌐 key is free — no system action",
                pendingText: "🌐 key still triggers a system action…")

            if model.fnTriggersSystemAction {
                Button("Open Keyboard Settings") {
                    NSWorkspace.shared.open(HotkeyController.keyboardSettingsURL)
                }
            }
        }
    }
}

// MARK: - Step 5: Mic test

private struct MicTestStep: View {
    let model: OnboardingModel
    let capture: AudioCapture

    @State private var level: Float = 0
    @State private var peakLevel: Float = 0
    @State private var deviceName = ""
    @State private var captureError: String?

    var body: some View {
        StepLayout(symbol: "waveform", title: "Test Your Microphone") {
            if model.micTestPassed {
                Label("Loud and clear!", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.voxiSuccess)
            } else {
                Text("Say something — “testing, one two three” works fine.")
                    .foregroundStyle(.secondary)
            }

            levelMeter
                .padding(.vertical, 6)

            if let captureError {
                VStack(spacing: 6) {
                    Label(captureError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.voxiWarning)
                    Button("Try Again") { startTest() }
                }
            } else if !deviceName.isEmpty {
                Label(deviceName, systemImage: "mic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Active input device: \(deviceName)")
            }
        }
        .onAppear { startTest() }
        .onDisappear { stopTest() }
    }

    /// Horizontal level bar with a tick at the pass threshold.
    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.voxiInset)
                Capsule()
                    .fill(model.micTestPassed ? AnyShapeStyle(Color.voxiSuccess) : AnyShapeStyle(.tint))
                    .frame(width: max(0, geo.size.width * CGFloat(min(1, level))))
                    .animation(.linear(duration: 0.06), value: level)
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 2)
                    .offset(x: geo.size.width * CGFloat(MicTestGate.successLevel))
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Microphone level")
    }

    private func startTest() {
        captureError = nil
        deviceName = AudioCapture.listInputDevices()
            .first(where: \.isDefault)?.name ?? "System default input"
        capture.onLevel = { newLevel in
            level = newLevel
            if newLevel > peakLevel { peakLevel = newLevel }
            if MicTestGate.passes(peakObservedLevel: peakLevel) {
                model.micTestPassed = true
            }
        }
        guard !capture.isCapturing else { return }
        do {
            try capture.start(deviceUID: nil)
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func stopTest() {
        capture.onLevel = nil
        if capture.isCapturing { capture.cancel() }
        level = 0
    }
}

// MARK: - Step 6: Hotkey summary

private struct HotkeySummaryStep: View {
    let hotkeys: HotkeyController

    var body: some View {
        StepLayout(symbol: "keyboard", title: "Your Hotkeys") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                chordRow(binding: hotkeys.pushToTalkBinding,
                         name: "Push to talk", detail: "Hold, speak, release to insert")
                chordRow(binding: hotkeys.toggleBinding,
                         name: "Hands-free", detail: "Press to start, press again to stop")
                chordRow(binding: hotkeys.commandBinding,
                         name: "Command mode", detail: "Dictate a task into the queue")
            }
            .padding(.top, 4)

            Text("You can change these anytime in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private func chordRow(binding: ChordBinding, name: String, detail: String) -> some View {
        GridRow {
            HStack(spacing: 4) {
                ForEach(ChordSymbols.parts(for: binding), id: \.self) { part in
                    Text(part)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .gridColumnAlignment(.trailing)
            .accessibilityLabel(ChordSymbols.label(for: binding))

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
