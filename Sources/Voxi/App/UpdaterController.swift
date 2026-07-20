import AppKit
import Observation
import Sparkle

/// Owns the Sparkle updater (feed + public key in Info.plist) and mirrors the
/// check lifecycle into an observable `status` for the Hub rail.
///
/// Feedback lives in the rail, not Sparkle's alerts: the app is an LSUIElement
/// agent and Sparkle's "You're up to date" alert can fail to front over one,
/// which read as "the button does nothing". The standard user driver still
/// runs the install flow when an update *is* found.
///
/// Automatic checks run in Release only: a Debug build shares the bundle id —
/// and therefore Sparkle's user-defaults scheduling keys — with the released
/// app, so a dev build must never start the updater or write its prefs.
/// Instantiating the controller with `startingUpdater: false` is inert, which
/// also keeps headless CLI runs (`CLIMode`) Sparkle-free until `start()`.
@MainActor
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    /// False in Debug builds, where the updater is never started (see above).
    /// The rail shows the control disabled with an explanation instead of a
    /// button that silently does nothing.
    let isAvailable: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Called from applicationDidFinishLaunching, after the CLIMode guard.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    /// User-initiated check from the Hub rail. The app is an LSUIElement
    /// agent, so Sparkle's windows need an explicit activate to come forward.
    func checkForUpdates() {
        guard isAvailable, status != .checking else { return }
        status = .checking
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// One-line rail caption for a status; nil when there is nothing to say.
    /// Pure so the mapping is unit-testable.
    static func statusLine(for status: Status) -> String? {
        switch status {
        case .idle: nil
        case .checking: "Checking…"
        case .upToDate: "You're up to date"
        case .updateAvailable(let version): "v\(version) available"
        case .failed: "Couldn't check for updates"
        }
    }

    // MARK: SPUUpdaterDelegate (Sparkle calls these on the main thread)

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            status = .updateAvailable(version: item.displayVersionString)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { status = .upToDate }
    }

    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            // didFind/didNotFind already resolved the outcome; only a cycle
            // that ended while still "checking" (network/appcast failure) is
            // a genuine error worth surfacing.
            if let error, status == .checking {
                status = .failed(message: error.localizedDescription)
            }
        }
    }
}
