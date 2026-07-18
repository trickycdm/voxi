import AppKit
import SwiftUI

/// State for the History tab: a live-updating recent list plus debounced FTS
/// search. The mode decision (`HistoryQuery.mode`) and this model's methods
/// are unit-tested; the debounce itself lives in the view's `.task(id:)`.
@MainActor
@Observable
final class HistoryModel {
    var searchText = ""
    private(set) var recent: [HistoryEntry] = []
    private(set) var searchResults: [HistoryEntry] = []

    let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    var mode: HistoryQueryMode { HistoryQuery.mode(for: searchText) }

    var displayed: [HistoryEntry] {
        switch mode {
        case .recent: recent
        case .search: searchResults
        }
    }

    /// Long-running: keeps `recent` in sync with the database. Run from the
    /// view's `.task` so it cancels with the view.
    func observeRecent() async {
        do {
            for try await rows in store.observeRecent(limit: 200) {
                recent = rows
            }
        } catch {
            voxiLog.warning("History observation ended: \(error.localizedDescription)")
        }
    }

    /// One-shot load, used by tests and as an observation fallback.
    func loadRecentOnce() async {
        recent = (try? await store.recent(limit: 200)) ?? []
    }

    /// Runs the FTS search for the current query (no debounce here).
    func searchNow() async {
        guard case .search(let query) = mode else {
            searchResults = []
            return
        }
        searchResults = (try? await store.search(query: query)) ?? []
    }

    func delete(_ entry: HistoryEntry) async {
        try? await store.delete(id: entry.id)
        searchResults.removeAll { $0.id == entry.id }
    }

    func clearAll() async {
        try? await store.deleteAll()
        searchResults = []
    }
}

/// Cached icon + display name lookups for target-app bundle IDs.
@MainActor
enum TargetAppInfo {
    private static var cache: [String: (name: String, icon: NSImage)?] = [:]

    static func lookup(bundleID: String) -> (name: String, icon: NSImage)? {
        if let cached = cache[bundleID] { return cached }
        let result: (String, NSImage)?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            result = (url.deletingPathExtension().lastPathComponent,
                      NSWorkspace.shared.icon(forFile: url.path))
        } else {
            result = nil
        }
        cache[bundleID] = result
        return result
    }
}

struct HistoryView: View {
    @State private var model: HistoryModel
    @State private var expandedID: HistoryEntry.ID?
    @State private var confirmingClearAll = false
    @FocusState private var searchFocused: Bool

    init(store: HistoryStore) {
        _model = State(initialValue: HistoryModel(store: store))
    }

    // Board layout (Pit Wall, direction A): no pane title — the rail carries
    // context. Search sits top-left, then a single full-width card ledger with
    // day rules; a tapped card expands in place to the full transcript.
    var body: some View {
        VStack(spacing: 0) {
            controls
            ledger
        }
        .task { await model.observeRecent() }
        .task(id: model.searchText) {
            // Debounce: typing restarts this task; only a 200ms-stable query hits FTS.
            guard case .search = model.mode else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await model.searchNow()
        }
        .confirmationDialog(
            "Delete all dictation history?",
            isPresented: $confirmingClearAll
        ) {
            Button("Delete All", role: .destructive) {
                Task { await model.clearAll() }
            }
        } message: {
            Text("This permanently deletes every saved dictation. This cannot be undone.")
        }
        // ⌘F focuses search now that `.searchable`'s toolbar shortcut is gone.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
                .accessibilityHidden(true)
        )
    }

    /// The ledger reads at a book-like measure: the board mock was composed
    /// at an 860 pt window, and full-bleed cards at desktop widths stretch
    /// transcript lines past any comfortable reading length. Everything —
    /// search row included — aligns to one centered column.
    private static let columnMaxWidth: CGFloat = 760

    private var controls: some View {
        HStack(spacing: Theme.Space.md) {
            HubSearchField(
                prompt: "Search dictations",
                text: $model.searchText,
                focus: $searchFocused)
            Spacer()
            Button("Clear All", systemImage: "trash") {
                confirmingClearAll = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.recent.isEmpty)
            .help("Delete all dictation history")
        }
        .frame(maxWidth: Self.columnMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.xl)
        // Top padding doubles as the hidden titlebar's drag strip.
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.md)
    }

    @ViewBuilder
    private var ledger: some View {
        if model.displayed.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if case .search = model.mode {
                        // FTS results are relevance-ranked — day sections
                        // would interleave, so search stays a flat list.
                        ForEach(model.displayed) { entry in
                            card(for: entry)
                        }
                    } else {
                        ForEach(HistoryDayGrouping.sections(model.displayed), id: \.title) { section in
                            dayHeader(section.title)
                            ForEach(section.entries) { entry in
                                card(for: entry)
                            }
                        }
                    }
                }
                .frame(maxWidth: Self.columnMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
            }
        }
    }

    private func dayHeader(_ title: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(title).voxiPlaque()
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
        }
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xs)
    }

    private func card(for entry: HistoryEntry) -> some View {
        HistoryCardView(
            entry: entry,
            isExpanded: expandedID == entry.id,
            onToggle: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = expandedID == entry.id ? nil : entry.id
                }
            },
            onDelete: {
                Task { await model.delete(entry) }
                if expandedID == entry.id { expandedID = nil }
            })
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .search = model.mode {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView(
                "No Dictations Yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Completed dictations appear here.")
            )
        }
    }

}

/// One board-style ledger card: time column, transcript preview, app chip and
/// word count; expands in place to the full transcript, raw-transcript
/// disclosure, metadata, and actions. Cards live on the Paper ground and
/// separate by tone (voxiCard), so ink tokens apply — the system-hierarchy
/// rule is only for rows inside selectable Lists.
struct HistoryCardView: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var justCopied = false

    private var appName: String {
        guard let bundleID = entry.targetAppBundleID else { return "Command" }
        return TargetAppInfo.lookup(bundleID: bundleID)?.name ?? bundleID
    }

    private var wordCount: Int {
        entry.finalText.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.voxiInk3)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if isExpanded {
                    Text(entry.finalText)
                        .foregroundStyle(Color.voxiInk)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                } else {
                    Text(entry.finalText)
                        .foregroundStyle(Color.voxiInk)
                        .lineSpacing(2)
                        .lineLimit(2)
                }
                meta
                if isExpanded {
                    expandedDetail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.md)
        .padding(.horizontal, Theme.Space.lg)
        .background(
            hovering && !isExpanded ? Color.voxiInset : Color.voxiCard,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        // Tap-to-open only; the expanded card collapses via its chevron so
        // clicks during text selection don't snap it shut.
        .onTapGesture { if !isExpanded { onToggle() } }
        .onHover { hovering = $0 }
    }

    private var meta: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.voxiInk2)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 2)
                .background(Color.voxiInset, in: Capsule())
            Text("\(wordCount) words · \(entry.engineID.capitalized)")
                .font(.caption)
                .foregroundStyle(Color.voxiInk3)
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            rawTranscriptSection
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
            metadata
            actions
        }
        .padding(.top, Theme.Space.sm)
    }

    @ViewBuilder
    private var rawTranscriptSection: some View {
        if entry.rawTranscript == entry.finalText {
            Text("Raw transcript identical to final text")
                .font(.caption)
                .foregroundStyle(Color.voxiInk3)
        } else {
            DisclosureGroup {
                Text(entry.rawTranscript)
                    .font(.callout)
                    .foregroundStyle(Color.voxiInk2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.md)
                    .background(Color.voxiInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .padding(.top, Theme.Space.sm)
            } label: {
                Text("Raw transcript").voxiPlaque()
            }
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.lg, verticalSpacing: 6) {
            metadataRow("Engine", "\(entry.engineID) · \(entry.modelID)")
            metadataRow("Refiner", entry.refinerID ?? "none")
            metadataRow("Duration", String(format: "%.1f s", entry.durationSeconds))
            metadataRow("Target", appName)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .voxiPlaque()
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.callout)
                .foregroundStyle(Color.voxiInk)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack {
            Button(justCopied ? "Copied" : "Copy Final Text",
                   systemImage: justCopied ? "checkmark" : "doc.on.doc") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.finalText, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    justCopied = false
                }
            }
            .buttonStyle(.bordered)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .buttonStyle(.borderless)
            Spacer()
            Button("Collapse", systemImage: "chevron.up", action: onToggle)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Collapse")
        }
    }
}
