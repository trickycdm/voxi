import AppKit
import SwiftUI

/// Borderless, non-activating floating panel hosting the pill's SwiftUI
/// content. It never steals focus from the app being dictated into, floats
/// over full-screen Spaces, and is only ever ordered in/out — never closed.
@MainActor
final class PillPanel: NSPanel {
    init(content: some View) {
        super.init(
            contentRect: .zero,
            // .nonactivatingPanel: clicks inside never activate our app, so
            // the frontmost app keeps keyboard focus for text insertion.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // .statusBar sits above normal and floating windows (menu-bar level).
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,      // follows Space switches
            .fullScreenAuxiliary,   // visible over other apps' full-screen Spaces
            .stationary,            // doesn't move during Exposé
            .ignoresCycle           // excluded from window cycling
        ]

        // Panels default this to true; a stray close() would over-release.
        isReleasedWhenClosed = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false

        let hosting = NSHostingView(rootView: content)
        // macOS 13+: SwiftUI's intrinsic content size drives the panel size.
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
    }

    // Borderless windows refuse key status by default; returning true lets
    // SwiftUI buttons inside respond on first click. Combined with
    // .nonactivatingPanel + becomesKeyOnlyIfNeeded the app never activates.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Bottom-center of the screen with keyboard focus. AppKit origin is
    /// bottom-left; visibleFrame already excludes the Dock and menu bar.
    func positionBottomCenter(padding: CGFloat = 24) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + padding)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
