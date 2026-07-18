import SwiftUI

/// The detail pane's header row: a real title plus the pane's primary
/// controls. Replaces the system titlebar/toolbar that left with the
/// NavigationSplitView — every Hub pane opens with one of these. Titles are
/// title-scale ink, not plaques; plaques stay supporting captions per
/// DESIGN_SYSTEM rule 6.
struct HubPaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.voxiInk)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Space.xl)
        // Top padding doubles as the hidden titlebar's drag strip.
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
    }
}

extension HubPaneHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// Replacement for `.searchable`, which needs a system toolbar to mount into.
/// Esc clears (parity with searchable); the caller owns focus so it can wire ⌘F.
struct HubSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.voxiInk3)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.voxiInk3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Theme.Space.sm)
        .background(Color.voxiInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .frame(width: 320)
    }
}
