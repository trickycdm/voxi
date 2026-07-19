import SwiftUI

/// Design tokens for the "Racing Green & Cream" system (steering/DESIGN_SYSTEM.md).
/// Colors resolve through asset-catalog color sets, one light ("Paddock") and one
/// dark ("Night Race") variant each — this file is the only place the asset names
/// appear as strings. Radii and spacing are the app-wide scales; UI code should
/// not introduce new literals for either.
enum Theme {
    enum Radius {
        static let control: CGFloat = 8   // fields, wells, small chrome
        static let card: CGFloat = 12     // queue cards, panels-in-panels
        static let panel: CGFloat = 18    // top-level panels
        // Chips and the pill stay Capsule.
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }
}

extension Color {
    // Grounds — tonal steps do the separating; reach for a hairline last.
    static let voxiPaper = Color("VoxiPaper")
    static let voxiCard = Color("VoxiCard")
    static let voxiInset = Color("VoxiInset")
    static let voxiHairline = Color("VoxiHairline")

    // Text tiers (replace .primary/.secondary/.tertiary in branded surfaces).
    static let voxiInk = Color("VoxiInk")
    static let voxiInk2 = Color("VoxiInk2")
    static let voxiInk3 = Color("VoxiInk3")

    // The live layer — the only sanctioned full-strength butter.
    static let voxiLive = Color("VoxiLive")
    // The pill's inset keyline; used nowhere else.
    static let voxiCoachline = Color("VoxiCoachline")
    // Command-mode identity: signal red, distinct from voxiDanger (status
    // colors belong to status). The pill pins dark appearance, so the dark
    // variant is the one that shows.
    static let voxiCommandTint = Color("VoxiCommand")

    // The Pit Wall rail (Hub sidebar) — racing green in BOTH appearances; the
    // rail pins .environment(\.colorScheme, .dark) so adaptive tokens inside
    // resolve Night Race, mirroring the pill's panel-level pin.
    static let voxiRacing = Color("VoxiRacing")
    // Rail selected-item fill: butter at 14% with the alpha baked into the
    // color set (the VoxiStatus*Bg pattern) — used nowhere else.
    static let voxiRailSelection = Color("VoxiRailSelection")

    // Semantic state (text/icons) — never borrowed for emphasis.
    static let voxiSuccess = Color("VoxiSuccess")
    static let voxiWarning = Color("VoxiWarning")
    static let voxiDanger = Color("VoxiDanger")

    // Status-chip fills (alpha baked into the color sets).
    static let voxiStatusQueuedBg = Color("VoxiStatusQueuedBg")
    static let voxiStatusDispatchedBg = Color("VoxiStatusDispatchedBg")
    static let voxiStatusRunningBg = Color("VoxiStatusRunningBg")
    static let voxiStatusSucceededBg = Color("VoxiStatusSucceededBg")
    static let voxiStatusFailedBg = Color("VoxiStatusFailedBg")
    static let voxiStatusDispatchedText = Color("VoxiStatusDispatchedText")
}

extension NSColor {
    // AppKit-side tokens for window chrome (NSWindow.backgroundColor).
    // Computed so nothing non-Sendable is stored in a global.
    static var voxiPaper: NSColor { NSColor(named: "VoxiPaper") ?? .windowBackgroundColor }
}

extension Text {
    /// Plaque label: the engraved-nameplate caption style — uppercase, tracked,
    /// tertiary ink. Section headers and metadata rows; not body copy.
    func voxiPlaque() -> some View {
        kerning(1.2)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.voxiInk3)
    }
}
