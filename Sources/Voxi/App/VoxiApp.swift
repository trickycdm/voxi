import SwiftUI

@main
struct VoxiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Template-rendered roundel (waveform in a circle) — the enamel-badge
        // brand mark; the system tints it for menu-bar appearance.
        MenuBarExtra("Voxi", image: "MenuBarRoundel") {
            MenuBarContent()
                .environment(appDelegate.appState)
        }

        // Title stays "Voxi Hub" for the Window menu and accessibility; the
        // titlebar itself is hidden so the Pit Wall rail runs full bleed with
        // the traffic lights overlaid on it.
        Window("Voxi Hub", id: "hub") {
            HubView()
                .environment(appDelegate.appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 560)
    }
}

/// AppKit entry point: owns long-lived controllers that shouldn't be tied to
/// any SwiftUI scene lifecycle (event tap, pill panel, database).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CLIMode.runIfRequested() { return }
        NSApp.setActivationPolicy(.accessory)
        appState.start()
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
        let view = OnboardingView(model: model, hotkeys: appState.hotkeys, capture: AudioCapture())
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
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if appState.hotkeys.permissionStatus != .active {
            Button("Grant Accessibility Permission…") {
                appState.hotkeys.requestAccessibility()
            }
            Divider()
        }

        Button("Open Hub") {
            openWindow(id: "hub")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("h")

        Button("Command Queue") {
            appState.openQueue()
        }
        .keyboardShortcut("j")

        Divider()

        Button("Run Onboarding Again") {
            (NSApp.delegate as? AppDelegate)?.showOnboarding()
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
