import Testing
@testable import Voxi

/// Pure rail-caption mapping for the update-check lifecycle. The Sparkle
/// delegate wiring itself needs a started updater and can't run headlessly.
@MainActor
@Suite struct UpdaterStatusTests {
    @Test func idleSaysNothing() {
        #expect(UpdaterController.statusLine(for: .idle) == nil)
    }

    @Test func lifecycleStatesRenderCaptions() {
        #expect(UpdaterController.statusLine(for: .checking) == "Checking…")
        #expect(UpdaterController.statusLine(for: .upToDate) == "You're up to date")
        #expect(UpdaterController.statusLine(for: .updateAvailable(version: "0.3.0"))
            == "v0.3.0 available")
        #expect(UpdaterController.statusLine(for: .failed(message: "offline"))
            == "Couldn't check for updates")
    }
}
