import SwiftUI

/// State for the Dictionary tab. Validation and CSV parsing are pure helpers
/// (`DictionaryValidation`, `VariantsCSV`) tested in HubFormattingTests;
/// persistence behavior is tested in HubModelsTests.
@MainActor
@Observable
final class DictionaryModel {
    private(set) var entries: [DictionaryEntry] = []
    private(set) var lastError: String?

    let store: DictionaryStore

    init(store: DictionaryStore) {
        self.store = store
    }

    func load() async {
        do {
            entries = try await store.all()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Validates and saves a term. When `existing` is provided and its term
    /// was renamed, the old row is removed first (the store upserts by term).
    /// Returns false when the term is invalid or the write failed.
    @discardableResult
    func save(term rawTerm: String, variantsCSV: String, replacing existing: DictionaryEntry? = nil) async -> Bool {
        guard let term = DictionaryValidation.normalizedTerm(rawTerm) else { return false }
        let variants = VariantsCSV.parse(variantsCSV)
        do {
            if let existing, existing.term.lowercased() != term.lowercased() {
                try await store.delete(id: existing.id)
            }
            var entry = existing ?? DictionaryEntry(term: term)
            entry.term = term
            entry.variants = variants
            try await store.upsert(entry)
            await load()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ entry: DictionaryEntry) async {
        do {
            try await store.delete(id: entry.id)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct DictionaryView: View {
    @State private var model: DictionaryModel
    @State private var addingEntry = false
    @State private var editingEntry: DictionaryEntry?

    init(store: DictionaryStore) {
        _model = State(initialValue: DictionaryModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            explainer
            Divider()
            content
        }
        .task { await model.load() }
        .toolbar {
            ToolbarItem {
                Button("Add Term", systemImage: "plus") { addingEntry = true }
                    .help("Add a dictionary term")
            }
        }
        .sheet(isPresented: $addingEntry) {
            DictionaryEditorSheet(model: model, entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEditorSheet(model: model, entry: entry)
        }
        .navigationTitle("Dictionary")
    }

    private var explainer: some View {
        Label(
            "Terms bias transcription toward your spelling, and the refiner enforces them — including the listed variants — in the final text.",
            systemImage: "character.book.closed"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            ContentUnavailableView(
                "No Terms",
                systemImage: "character.book.closed",
                description: Text("Add names, acronyms, and jargon so they come out spelled right.")
            )
        } else {
            List(model.entries) { entry in
                DictionaryRowView(entry: entry) {
                    editingEntry = entry
                } onDelete: {
                    Task { await model.delete(entry) }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct DictionaryRowView: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .fontWeight(.medium)
                if !entry.variants.isEmpty {
                    Text("also heard as: \(VariantsCSV.join(entry.variants))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Edit", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Edit term")
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete term")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

struct DictionaryEditorSheet: View {
    let model: DictionaryModel
    let entry: DictionaryEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var variantsCSV: String

    init(model: DictionaryModel, entry: DictionaryEntry?) {
        self.model = model
        self.entry = entry
        _term = State(initialValue: entry?.term ?? "")
        _variantsCSV = State(initialValue: VariantsCSV.join(entry?.variants ?? []))
    }

    private var isValid: Bool {
        DictionaryValidation.normalizedTerm(term) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "Add Term" : "Edit Term")
                .font(.headline)
            Form {
                TextField("Term", text: $term, prompt: Text("e.g. GRDB"))
                TextField(
                    "Variants",
                    text: $variantsCSV,
                    prompt: Text("comma-separated, e.g. gee are dee bee, grdb")
                )
                Text("Variants are misheard spellings that should be corrected to the term.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await model.save(term: term, variantsCSV: variantsCSV, replacing: entry) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
