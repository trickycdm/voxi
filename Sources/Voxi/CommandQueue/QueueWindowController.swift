import AppKit
import SwiftUI

/// Owns the Queue window: one lazily created NSWindow for the app's
/// lifetime, summonable and dismissible from anywhere (menu bar, hotkey
/// flow after a card lands). Final scene wiring happens at integration.
@MainActor
final class QueueWindowController {
    private let model: QueueModel
    private let runner: QueueRunner
    private let resolver: any DispatcherResolving
    private var window: NSWindow?

    init(model: QueueModel, runner: QueueRunner, resolver: any DispatcherResolving) {
        self.model = model
        self.runner = runner
        self.resolver = resolver
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voxi Queue"
        // The controller reuses one window for the app's lifetime; closing
        // must hide, not deallocate.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("VoxiQueueWindow")
        window.contentView = NSHostingView(
            rootView: QueueView(model: model, runner: runner, resolver: resolver)
        )
        return window
    }
}
