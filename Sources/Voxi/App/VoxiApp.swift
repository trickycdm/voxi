import SwiftUI

@main
struct VoxiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Voxi", systemImage: "mic.fill") {
            MenuBarContent()
                .environment(appDelegate.appState)
        }
    }
}

/// AppKit entry point: owns long-lived controllers that shouldn't be tied to
/// any SwiftUI scene lifecycle (event tap, pill panel, database).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text("Voxi \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        Divider()
        Button("Quit Voxi") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
