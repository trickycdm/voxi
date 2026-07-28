import SwiftUI

@main
struct VoxiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Template-rendered roundel (waveform in a circle) — the enamel-badge
        // brand mark; the system tints it for menu-bar appearance.
        MenuBarExtra("Voxi", image: "MenuBarRoundel") {
            // showOnboarding is injected as a closure: NSApp.delegate is
            // SwiftUI's own wrapper under @NSApplicationDelegateAdaptor, so
            // casting it to AppDelegate fails silently.
            MenuBarContent(showOnboarding: { appDelegate.showOnboarding() })
                .environment(appDelegate.appState)
        }
        // The Hub is a controller-owned NSWindow (HubWindowController), not a
        // SwiftUI Window scene: AppState must be able to open it and deep-link
        // a section from the menu bar and notification taps, and openWindow
        // only exists inside a scene's environment.
    }
}

/// AppKit entry point: owns long-lived controllers that shouldn't be tied to
/// any SwiftUI scene lifecycle (event tap, pill panel, database).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let updater = UpdaterController()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CLIMode.runIfRequested() { return }
        NSApp.setActivationPolicy(.accessory)
        appState.start(updater: updater)
        updater.start()
        if OnboardingModel.shouldShow() {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    /// Onboarding lives in a plain NSWindow because it must open at first
    /// launch, before any SwiftUI scene has an openWindow environment.
    func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = OnboardingModel()
        // The mic test gets its own AudioCapture: AudioCapture is one-consumer
        // (single onLevel slot, exclusive engine), and sharing AppState's
        // instance let the mic test steal — then nil — the pill's level sink.
        let view = OnboardingView(
            model: model, hotkeys: appState.hotkeys, capture: AudioCapture(),
            registry: appState.registry, inserter: appState.inserter)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Voxi"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .voxiPaper
        window.center()
        model.onFinished = { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarContent: View {
    let showOnboarding: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.hotkeys.permissionStatus != .active {
            Button("Grant Accessibility Permission…") {
                appState.hotkeys.requestAccessibility()
            }
            Divider()
        }

        // Read-only chord hints; bare Text renders as a disabled row (same
        // pattern as the error row below). Live-updates via @Observable when
        // a chord is rebound in the Hub.
        Text("Push to talk: \(ChordSymbols.render(appState.hotkeys.pushToTalkBinding)) (hold)")
        Text("Hands-free: \(ChordSymbols.render(appState.hotkeys.toggleBinding))")
        Text("Command mode: \(ChordSymbols.render(appState.hotkeys.commandBinding)) (hold)")

        Divider()

        Button("Open Hub") {
            appState.openHub()
        }
        .keyboardShortcut("h")

        Button("Command Queue") {
            appState.openHub(section: .queue)
        }
        .keyboardShortcut("j")

        Divider()

        Button("Run Onboarding Again") {
            showOnboarding()
        }

        if let error = appState.lastError {
            Divider()
            Text(error)
        }

        Divider()

        Button("Quit Voxi") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
