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
            } else {
                List(model.displayed, selection: $selectionID) { entry in
                    HistoryRowView(entry: entry)
                        .tag(entry.id)
                }
                .listStyle(.inset)
            }
        }
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
                systemImage: "text.magnifyingglass",
                description: Text("Select a dictation to see its details.")
            )
        }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.finalText)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let bundleID = entry.targetAppBundleID {
                    if let info = TargetAppInfo.lookup(bundleID: bundleID) {
                        Image(nsImage: info.icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                        Text(info.name)
                    } else {
                        Text(bundleID)
                    }
                } else {
                    Image(systemName: "bolt.badge.clock")
                    Text("Command")
                }
                Text(entry.engineID)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(entry.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                transcriptBox("Raw Transcript", text: entry.rawTranscript)
                transcriptBox("Final Text", text: entry.finalText)
            }
            .frame(maxHeight: .infinity)

            metadata

            HStack {
                Button("Copy Final Text", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(entry.finalText, forType: .string)
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .padding()
    }

    private func transcriptBox(_ title: String, text: String) -> some View {
        GroupBox(title) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            metadataRow("Engine", "\(entry.engineID) · \(entry.modelID)")
            metadataRow("Refiner", entry.refinerID ?? "none")
            metadataRow("Duration", String(format: "%.1f s", entry.durationSeconds))
            metadataRow(
                "Target app",
                entry.targetAppBundleID.map {
                    TargetAppInfo.lookup(bundleID: $0)?.name ?? $0
                } ?? "Command mode"
            )
            metadataRow("Date", entry.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.callout)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
