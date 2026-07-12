import AppKit
import SwiftUI

/// Owns the full-log viewer windows: one lazily created NSWindow per card,
/// reused on re-open so two runs' logs can sit side by side. Windows are
/// kept for the app's lifetime and hidden on close, never deallocated
/// (same lifecycle rule as the queue window).
@MainActor
final class LogWindowController {
    private let model: QueueModel
    private let runner: QueueRunner
    private var windows: [UUID: NSWindow] = [:]

    init(model: QueueModel, runner: QueueRunner) {
        self.model = model
        self.runner = runner
    }

    func show(card: ActionCard) {
        let window = windows[card.id] ?? makeWindow(for: card)
        windows[card.id] = window
        window.title = "Log — \(card.title)"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(for card: ActionCard) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: LogViewerView(cardID: card.id, model: model, runner: runner)
        )
        return window
    }
}
