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
    @State private var selectionID: HistoryEntry.ID?
    @State private var confirmingClearAll = false

    init(store: HistoryStore) {
        _model = State(initialValue: HistoryModel(store: store))
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 280, idealWidth: 340)
            detailPane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $model.searchText, prompt: "Search dictations")
        .task { await model.observeRecent() }
        .task(id: model.searchText) {
            // Debounce: typing restarts this task; only a 200ms-stable query hits FTS.
            guard case .search = model.mode else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await model.searchNow()
        }
        .toolbar {
            ToolbarItem {
                Button("Clear All", systemImage: "trash") {
                    confirmingClearAll = true
                }
                .disabled(model.recent.isEmpty)
                .help("Delete all dictation history")
            }
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
        .navigationTitle("History")
    }

    private var listPane: some View {
        Group {
            if model.displayed.isEmpty {
                emptyState
            } else if case .search = model.mode {
                // FTS results are relevance-ranked — day sections would
                // interleave, so search stays a flat list.
                List(model.displayed, selection: $selectionID) { entry in
                    HistoryRowView(entry: entry)
                        .tag(entry.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                List(selection: $selectionID) {
                    ForEach(HistoryDayGrouping.sections(model.displayed), id: \.title) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                HistoryRowView(entry: entry)
                                    .tag(entry.id)
                            }
                        } header: {
                            Text(section.title).voxiPlaque()
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.voxiPaper)
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

    @ViewBuilder
    private var detailPane: some View {
        if let entry = model.displayed.first(where: { $0.id == selectionID }) {
            HistoryDetailView(entry: entry) {
                Task { await model.delete(entry) }
                selectionID = nil
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "waveform",
                description: Text("Select a dictation to read it in full.")
            )
        }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry

    // Rows keep the system text hierarchy (.primary/.secondary) rather than
    // ink tokens: List flips these automatically when the row is selected,
    // and fixed ink-on-accent would be unreadable in light mode.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            kindBadge
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.finalText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(appName)
                    Text(entry.engineID)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    Spacer()
                    Text(entry.createdAt, format: .relative(presentation: .named))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }

    private var appName: String {
        guard let bundleID = entry.targetAppBundleID else { return "Command" }
        return TargetAppInfo.lookup(bundleID: bundleID)?.name ?? bundleID
    }

    @ViewBuilder
    private var kindBadge: some View {
        if let bundleID = entry.targetAppBundleID,
           let info = TargetAppInfo.lookup(bundleID: bundleID) {
            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onDelete: () -> Void

    @State private var justCopied = false

    private var appName: String {
        entry.targetAppBundleID.map {
            TargetAppInfo.lookup(bundleID: $0)?.name ?? $0
        } ?? "Command mode"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header

                // The dictated words are the content; everything else steps back.
                Text(entry.finalText)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Color.voxiInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.lg)
                    .background(Color.voxiCard, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.voxiHairline, lineWidth: 1))

                rawTranscriptSection

                Rectangle().fill(Color.voxiHairline).frame(height: 1)

                metadata
            }
            .padding(Theme.Space.xl)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.targetAppBundleID == nil ? "Command · \(appName)" : "Dictation · \(appName)")
                .voxiPlaque()
            Spacer()
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.voxiInk3)
        }
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

    private var actionBar: some View {
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
            .buttonStyle(.borderedProminent)
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
        .background(Color.voxiPaper)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
        }
    }
}
