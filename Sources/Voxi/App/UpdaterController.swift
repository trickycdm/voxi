import AppKit
import Sparkle

/// Owns the Sparkle updater (feed + public key in Info.plist).
///
/// Automatic checks run in Release only: a Debug build shares the bundle id —
/// and therefore Sparkle's user-defaults scheduling keys — with the released
/// app, so a dev build must never start the updater or write its prefs.
/// Instantiating the controller with `startingUpdater: false` is inert, which
/// also keeps headless CLI runs (`CLIMode`) Sparkle-free until `start()`.
@MainActor
final class UpdaterController {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    /// Called from applicationDidFinishLaunching, after the CLIMode guard.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    /// User-initiated check from the tray menu. The app is an LSUIElement
    /// agent, so Sparkle's windows need an explicit activate to come forward.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
