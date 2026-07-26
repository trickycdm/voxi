import SwiftUI

/// State for the Dictionary tab. Validation and CSV parsing are pure helpers
/// (`DictionaryValidation`, `VariantsCSV`) tested in HubFormattingTests;
/// persistence behavior is tested in HubModelsTests.
@MainActor
@Observable
final class DictionaryModel {
    private(set) var entries: [DictionaryEntry] = []
    private(set) var learned: [LearnedCorrection] = []
    private(set) var lastError: String?

    let store: DictionaryStore
    let learnedStore: LearnedCorrectionStore

    init(store: DictionaryStore, learnedStore: LearnedCorrectionStore) {
        self.store = store
        self.learnedStore = learnedStore
    }

    func load() async {
        do {
            entries = try await store.all()
            learned = try await learnedStore.all()
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
            // Learned pairs are enforced through the entry — with it gone,
            // drop them from the learned list too so it never shows pairs
            // that no longer do anything.
            try await learnedStore.deleteAll(right: entry.term)
            await load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes a learned pair AND stops enforcing it: the `wrong` variant is
    /// stripped from the matching dictionary entry. A bare term is kept —
    /// it may have been added manually, and still usefully biases the ASR.
    func unlearn(_ correction: LearnedCorrection) async {
        do {
            try await learnedStore.delete(id: correction.id)
            if var entry = try await store.all().first(where: {
                $0.term.caseInsensitiveCompare(correction.right) == .orderedSame
            }) {
                entry.variants.removeAll {
                    $0.caseInsensitiveCompare(correction.wrong) == .orderedSame
                }
                try await store.upsert(entry)
            }
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

    init(store: DictionaryStore, learnedStore: LearnedCorrectionStore) {
        _model = State(initialValue: DictionaryModel(store: store, learnedStore: learnedStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubPaneHeader("Dictionary") {
                Button("Add Term", systemImage: "plus") { addingEntry = true }
                    .help("Add a dictionary term")
            }
            explainer
            content
        }
        .task { await model.load() }
        .sheet(isPresented: $addingEntry) {
            DictionaryEditorSheet(model: model, entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEditorSheet(model: model, entry: entry)
        }
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
        if model.entries.isEmpty && model.learned.isEmpty {
            ContentUnavailableView(
                "No Terms",
                systemImage: "character.book.closed",
                description: Text("Add names, acronyms, and jargon so they come out spelled right.")
            )
            // Greedy frame so the enclosing VStack fills the detail pane:
            // without it the whole stack hugs content and floats mid-window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.entries.isEmpty {
                    Section("Terms") {
                        ForEach(model.entries) { entry in
                            DictionaryRowView(entry: entry) {
                                editingEntry = entry
                            } onDelete: {
                                Task { await model.delete(entry) }
                            }
                        }
                    }
                }
                Section("Learned Corrections") {
                    if model.learned.isEmpty {
                        Text("Corrections you make within a few seconds of a dictation landing will show up here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.learned) { correction in
                            LearnedCorrectionRowView(correction: correction) {
                                Task { await model.unlearn(correction) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// One learned wrong→right pair with when it was picked up. Delete forgets
/// the pair and stops enforcing it (strips the dictionary variant).
struct LearnedCorrectionRowView: View {
    let correction: LearnedCorrection
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(correction.wrong).foregroundStyle(.secondary)
                    + Text(" → ").foregroundStyle(.secondary)
                    + Text(correction.right).fontWeight(.medium))
                    .lineLimit(1)
                Text("Learned \(correction.learnedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Forget this correction and stop applying it")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Forget", role: .destructive, action: onDelete)
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
