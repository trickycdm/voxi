import AppKit
import SwiftUI

/// Borderless, non-activating floating panel hosting the pill's SwiftUI
/// content. It never steals focus from the app being dictated into, floats
/// over full-screen Spaces, and is only ever ordered in/out — never closed.
@MainActor
final class PillPanel: NSPanel {
    private var frameObserver: (any NSObjectProtocol)?

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

        // That sizing resizes the panel around a fixed bottom-left origin, so
        // a state change that widens the content walks the pill off-centre to
        // the right. Watch the content's size and re-pin the midline.
        hosting.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hosting, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so main-actor isolation holds.
            MainActor.assumeIsolated { self?.recenterAfterContentResize() }
        }
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

    /// Keep the capsule's centre on the screen's midline through content size
    /// changes. Bottom edge stays anchored (AppKit origin is bottom-left, so
    /// height growth already extends upward); only x needs correcting. Uses
    /// the panel's own screen so a mid-session resize can't yank the pill to
    /// another display.
    private func recenterAfterContentResize() {
        guard isVisible, let size = contentView?.frame.size else { return }
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let target = NSRect(
            origin: NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: frame.minY),
            size: size
        )
        // Our own setFrame refires the frame notification; this equal-frame
        // early-return is the loop's exit condition.
        guard target != frame else { return }
        setFrame(target, display: true)
    }
}
