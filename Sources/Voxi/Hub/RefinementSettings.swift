import SwiftUI

/// Editing state for the Refinement settings section. `config` is a working
/// copy: backend + model selection persist the moment they change, credential
/// fields wait for the explicit Save. Round-trip, auto-save split, and
/// dirty-tracking are unit-tested.
@MainActor
@Observable
final class RefinementModel {
    enum TestState: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    var config: RefinerConfig {
        didSet {
            if config != oldValue { testState = .idle }
            autoSavePickerChanges(oldValue: oldValue)
        }
    }
    private(set) var savedConfig: RefinerConfig
    private(set) var testState: TestState = .idle

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = RefinerConfig.load(from: defaults)
        config = loaded
        savedConfig = loaded
    }

    var isDirty: Bool { config != savedConfig }

    /// Only the credential backends need the explicit Save button — backend
    /// and model selection persist on change.
    var showsSaveButton: Bool {
        config.backend == .openAICompat || config.backend == .anthropic
    }

    func save() {
        config.save(to: defaults)
        savedConfig = config
    }

    /// Backend + on-device model choice aren't credentials: persist them the
    /// moment they change (a selected model row that silently needed Save was
    /// a trap). Credential fields stay behind isDirty/Save.
    private func autoSavePickerChanges(oldValue: RefinerConfig) {
        guard config.backend != oldValue.backend
                || config.localModelID != oldValue.localModelID else { return }
        var persisted = savedConfig
        persisted.backend = config.backend
        persisted.localModelID = config.localModelID
        persisted.save(to: defaults)
        savedConfig = persisted
    }

    /// Tests the *currently edited* configuration (no save required).
    func testConnection() async {
        testState = .testing
        if config.backend == .rules {
            testState = .ok("Rule-based refinement is built in and always available.")
            return
        }
        guard let refiner = config.makeLLMRefiner() else {
            testState = .failed(config.backend == .localLLM
                ? "On-device model not downloaded — download it below."
                : "Configuration incomplete — fill in the required fields.")
            return
        }
        do {
            try await refiner.testConnection()
            testState = .ok("Connected to \(refiner.displayName).")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}

/// Download/delete state for the on-device GGUF models, presented through the
/// same `ModelRowView` rows as the speech models (descriptors mapped to
/// `ASRModelInfo`). Selection lives in `RefinerConfig.localModelID` and
/// persists on change via RefinementModel's auto-save.
@MainActor
@Observable
final class LocalLLMModel {
    private(set) var rows: [ASRModelInfo] = []
    /// modelID → 0...1 while a download is in flight.
    private(set) var downloadProgress: [String: Double] = [:]
    var errorMessage: String?

    private let downloader = LocalLLMDownloader()
    private let modelsDir = VoxiPaths.modelsDir(engineID: LocalLLMCatalog.engineID)

    func refresh() {
        rows = LocalLLMCatalog.curated.map { descriptor in
            ASRModelInfo(
                id: descriptor.id,
                displayName: descriptor.displayName,
                sizeMB: descriptor.sizeMB,
                isDownloaded: LocalLLMCatalog.isDownloaded(descriptor, under: modelsDir),
                isRecommended: descriptor.isRecommended
            )
        }
    }

    func download(_ modelID: String) async {
        guard let descriptor = LocalLLMCatalog.descriptor(for: modelID),
              downloadProgress[modelID] == nil else { return }
        downloadProgress[modelID] = 0
        do {
            try await downloader.download(descriptor, to: modelsDir) { [weak self] progress in
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
        refresh()
    }

    func delete(_ modelID: String) async {
        guard let descriptor = LocalLLMCatalog.descriptor(for: modelID) else { return }
        await LocalLLMEngine.shared.unload()
        await downloader.delete(descriptor, from: modelsDir)
        refresh()
    }
}

struct RefinementSettingsSection: View {
    @State private var model = RefinementModel()
    @State private var localModels = LocalLLMModel()

    var body: some View {
        refinementSection
        onDeviceModelSection
    }

    /// Bay 1: backend choice, per-backend credential fields, Test Connection.
    private var refinementSection: some View {
        Section {
            Picker("Backend", selection: $model.config.backend) {
                ForEach(RefinerBackendID.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            switch model.config.backend {
            case .rules, .localLLM:
                EmptyView()
            case .openAICompat:
                TextField(
                    "Base URL",
                    text: $model.config.openAIBaseURL,
                    prompt: Text("http://localhost:11434")
                )
                .autocorrectionDisabled()
                TextField(
                    "Model",
                    text: $model.config.openAIModel,
                    prompt: Text("e.g. llama3.2")
                )
                .autocorrectionDisabled()
                SecureField(
                    "API key (optional)",
                    text: $model.config.openAIAPIKey
                )
            case .anthropic:
                SecureField("API key", text: $model.config.anthropicAPIKey)
                TextField(
                    "Model",
                    text: $model.config.anthropicModel,
                    prompt: Text(AnthropicRefiner.defaultModel)
                )
                .autocorrectionDisabled()
            }

            HStack {
                if model.showsSaveButton {
                    Button("Save") { model.save() }
                        .disabled(!model.isDirty)
                }
                Button("Test Connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.testState == .testing)
                testStatus
            }
        } header: {
            Text("Refinement").voxiPlaque()
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let footnote = backendFootnote {
                    Text(footnote)
                }
                Text("Rule-based cleanup always runs as a fallback, and everything works offline without an LLM.")
            }
        }
    }

    /// Bay 2: the on-device model garage. Always present — model files exist
    /// independent of the selected backend, and this keeps the section
    /// anatomy identical to Speech.
    private var onDeviceModelSection: some View {
        Section {
            ForEach(localModels.rows) { info in
                ModelRowView(
                    info: info,
                    isSelected: model.config.localModelID == info.id,
                    progress: localModels.downloadProgress[info.id],
                    onDownload: { Task { await localModels.download(info.id) } },
                    onDelete: { Task { await localModels.delete(info.id) } },
                    onSelect: { model.config.localModelID = info.id }
                )
            }
            if model.config.backend == .localLLM,
               !localModels.rows.isEmpty,
               !localModels.rows.contains(where: {
                   $0.id == model.config.localModelID && $0.isDownloaded
               }) {
                Label(
                    "Model not downloaded — refinement falls back to rules.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Color.voxiWarning)
            }
            if let error = localModels.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.voxiDanger)
            }
        } header: {
            Text("On-Device Model").voxiPlaque()
        } footer: {
            Text("Models are stored locally and can be deleted anytime.")
        }
        .task { localModels.refresh() }
    }

    /// One extra footer line about the *selected* backend, not all of them.
    private var backendFootnote: String? {
        switch model.config.backend {
        case .rules:
            nil
        case .localLLM:
            "A small model refines text right on this Mac — nothing leaves it, no key needed."
        case .openAICompat:
            "Covers Ollama, LM Studio, and llama.cpp servers."
        case .anthropic:
            "Your key is stored on this Mac and used only for refinement calls."
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.voxiSuccess)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.voxiDanger)
                .font(.callout)
                .lineLimit(2)
        }
    }
}
