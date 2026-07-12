import SwiftUI

/// Engine + model management for the Speech Recognition settings section.
/// Wraps ASREngineRegistry (selection persistence) and the selected engine's
/// model catalog (download/delete with progress).
@MainActor
@Observable
final class SpeechModel {
    let registry: ASREngineRegistry

    /// Persisted immediately; the catalog reload is driven by the view's
    /// `.task(id: selectedEngineID)` (and by tests calling `loadModels()`).
    var selectedEngineID: String {
        didSet {
            guard oldValue != selectedEngineID else { return }
            registry.selectedEngineID = selectedEngineID
            models = []
        }
    }

    private(set) var models: [ASRModelInfo] = []
    private(set) var selectedModelID: String?
    /// modelID → 0...1 while a download is in flight.
    private(set) var downloadProgress: [String: Double] = [:]
    var errorMessage: String?

    init(registry: ASREngineRegistry) {
        self.registry = registry
        selectedEngineID = registry.selectedEngineID
    }

    var engine: (any ASREngine)? {
        registry.engine(withID: selectedEngineID)
    }

    func loadModels() async {
        guard let engine else { return }
        selectedModelID = registry.selectedModelID(for: engine.id)
        do {
            models = try await engine.availableModels()
        } catch {
            errorMessage = "Could not list models: \(error.localizedDescription)"
        }
    }

    func download(_ modelID: String) async {
        guard let engine, downloadProgress[modelID] == nil else { return }
        downloadProgress[modelID] = 0
        do {
            try await engine.downloadModel(modelID) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadProgress[modelID] != nil else { return }
                    self.downloadProgress[modelID] = progress
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
        downloadProgress[modelID] = nil
        await loadModels()
    }

    func delete(_ modelID: String) async {
        guard let engine else { return }
        do {
            try await engine.deleteModel(modelID)
            errorMessage = nil
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        await loadModels()
    }

    func select(_ modelID: String) {
        registry.setSelectedModel(modelID, for: selectedEngineID)
        selectedModelID = modelID
    }
}

struct SpeechSettingsSection: View {
    @State private var model: SpeechModel

    init(registry: ASREngineRegistry) {
        _model = State(initialValue: SpeechModel(registry: registry))
    }

    var body: some View {
        Section {
            Picker("Engine", selection: $model.selectedEngineID) {
                ForEach(model.registry.engines, id: \.id) { engine in
                    Text(engine.displayName).tag(engine.id)
                }
            }

            if model.models.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model catalog…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.models) { info in
                    ModelRowView(
                        info: info,
                        isSelected: model.selectedModelID == info.id,
                        progress: model.downloadProgress[info.id],
                        onDownload: { Task { await model.download(info.id) } },
                        onDelete: { Task { await model.delete(info.id) } },
                        onSelect: { model.select(info.id) }
                    )
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.voxiDanger)
            }
        } header: {
            Text("Speech Recognition").voxiPlaque()
        } footer: {
            Text("Engine and model changes take effect on the next dictation. When no model is chosen, the recommended one is used.")
        }
        .task(id: model.selectedEngineID) { await model.loadModels() }
    }
}

struct ModelRowView: View {
    let info: ASRModelInfo
    let isSelected: Bool
    /// Non-nil while downloading.
    let progress: Double?
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName)
                    if info.isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(ModelSizeFormat.label(forMB: info.sizeMB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let progress {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if info.isDownloaded {
                if isSelected {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.voxiSuccess)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Use") { onSelect() }
                        .help("Use this model for dictation")
                }
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete the downloaded model files")
            } else {
                Button("Download", systemImage: "arrow.down.circle") { onDownload() }
            }
        }
        .padding(.vertical, 2)
    }
}
