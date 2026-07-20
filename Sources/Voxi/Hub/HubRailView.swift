import SwiftUI

/// The Pit Wall: the Hub's fixed-width sidebar rail. Racing green in both
/// system appearances — `.environment(\.colorScheme, .dark)` pins the subtree
/// so every adaptive token inside resolves to its Night Race variant (the
/// SwiftUI-level mirror of the pill's `NSAppearance(.darkAqua)` pin). Must
/// stay pure SwiftUI: AppKit-hosted controls would not follow the pin.
struct HubRailView: View {
    @Binding var selection: HubView.HubSection
    @Environment(AppState.self) private var appState
    @State private var status = EngineStatusLine.standby

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                // Clears the traffic lights overlaid by the hidden titlebar.
                .padding(.top, 40)
                .padding(.bottom, Theme.Space.xl)
            ForEach(Array(HubView.HubSection.allCases.enumerated()), id: \.element) { index, section in
                RailItem(section: section, index: index, selection: $selection)
            }
            Spacer()
            footer
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.lg)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color.voxiRacing)
        .environment(\.colorScheme, .dark)
        .task { await pollStatus() }
    }

    private var brandHeader: some View {
        HStack(spacing: Theme.Space.sm) {
            Image("MenuBarRoundel")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.accentColor)
            Text("VOXI")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3.5)
                .foregroundStyle(Color.voxiInk)
        }
        .padding(.horizontal, Theme.Space.md)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Circle()
                    .fill(status.isReady ? Color.voxiSuccess : Color.voxiInk3)
                    .frame(width: 6, height: 6)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(Color.voxiInk2)
            }
            .help("Speech engine status")
            Text(Self.versionLine)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.voxiInk3)
                .accessibilityLabel("Voxi version \(Self.semver)")
        }
        .padding(.horizontal, Theme.Space.md)
    }

    /// Semver from the bundle (CFBundleShortVersionString), stamped by
    /// project.yml at build time. Missing only in malformed bundles.
    private static let semver =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private static let versionLine = "v\(semver)"

    /// The registry is @MainActor but not @Observable, so the footer polls
    /// three cheap synchronous reads while the Hub is open; cancels with the
    /// view. Status niceties don't warrant an observation wrapper.
    private func pollStatus() async {
        while !Task.isCancelled {
            status = EngineStatusLine.make(
                engineDisplayName: appState.registry.selectedEngine.displayName,
                selectedEngineID: appState.registry.selectedEngineID,
                loadedEngineID: appState.registry.loadedEngineID)
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// One rail navigation entry. Selection is butter on the baked-alpha butter
/// fill; hover is a faint ink lift. ⌘1/2/3 mirror the Finder/Mail convention.
private struct RailItem: View {
    let section: HubView.HubSection
    let index: Int
    @Binding var selection: HubView.HubSection
    @State private var hovering = false

    private var isSelected: Bool { selection == section }

    var body: some View {
        Button {
            selection = section
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.sm)
                .padding(.horizontal, Theme.Space.md)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.voxiInk2)
        .background(
            isSelected
                ? Color.voxiRailSelection
                : hovering ? Color.voxiInk.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
    }
}
