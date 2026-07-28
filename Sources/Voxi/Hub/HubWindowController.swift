import AppKit
import SwiftUI

/// Owns the Hub window: one lazily created NSWindow for the app's lifetime,
/// summonable from the menu bar and notification taps. Controller-owned (not
/// a SwiftUI `Window` scene) so AppState can open it and deep-link a section
/// programmatically — `openWindow` only exists inside a scene's environment.
@MainActor
final class HubWindowController {
    let router = HubRouter()
    // App-lifetime peers owned by AppDelegate/AppState; unowned breaks the
    // formal AppState ↔ HubWindowController cycle.
    private unowned let appState: AppState
    private let updater: UpdaterController
    private var window: NSWindow?

    init(appState: AppState, updater: UpdaterController) {
        self.appState = appState
        self.updater = updater
    }

    func show(section: HubSection? = nil, revealCard cardID: UUID? = nil) {
        if let cardID { router.pendingQueueCardID = cardID }
        if let section { router.section = section }
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title stays set for the Window menu and accessibility; the titlebar
        // itself is hidden so the Pit Wall rail runs full bleed with the
        // traffic lights overlaid on it (rail clears them with top padding).
        window.title = "Voxi Hub"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The controller reuses one window for the app's lifetime; closing
        // must hide, not deallocate.
        window.isReleasedWhenClosed = false
        window.backgroundColor = .voxiPaper
        // Rail 196 + queue list 300 + hairline + ~383 for CardDetailView's
        // controls row (see DESIGN_SYSTEM.md).
        window.contentMinSize = NSSize(width: 880, height: 520)
        if !window.setFrameUsingName("VoxiHubWindow") {
            window.center()
        }
        window.setFrameAutosaveName("VoxiHubWindow")
        // Both environments are load-bearing: HubRailView reads AppState and
        // UpdaterController; a missing one crashes or blanks the rail.
        window.contentView = NSHostingView(
            rootView: HubView(router: router)
                .environment(appState)
                .environment(updater)
        )
        return window
    }
}
