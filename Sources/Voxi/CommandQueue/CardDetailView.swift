import SwiftUI

/// Expanded card: editable prompt, dispatcher parameters, dispatch/cancel/
/// retry controls, live log, result summary, and the raw-transcript
/// disclosure with its refinement badge.
struct CardDetailView: View {
    let card: ActionCard
    let model: QueueModel
    let runner: QueueRunner
    let resolver: any DispatcherResolving
    /// Opens the card's full log window (threaded down from AppState).
    var openLog: ((ActionCard) -> Void)? = nil

    @State private var promptDraft = ""
    @State private var params: [String: String] = [:]
    @State private var lastError: String?

    private var isEditable: Bool { card.status == .queued }

    private var dispatcher: (any Dispatcher)? {
        resolver.dispatcher(for: card.dispatcherID)
    }

    private var paramSpecs: [DispatcherParamSpec] {
        dispatcher?.paramSpecs ?? []
    }

    private var canDispatch: Bool {
        QueueLogic.canDispatch(status: card.status, prompt: promptDraft, params: params, specs: paramSpecs)
            && dispatcher != nil
            && !runner.isActive(card.id)
    }

    private var displayLog: String {
        QueueLogic.displayLog(
            status: card.status,
            liveTail: runner.liveRuns[card.id]?.logTail,
            persistedLog: card.log)
    }

    private var resultSummary: String? {
        switch card.status {
        case .succeeded, .failed:
            var line = card.status == .succeeded ? "Succeeded" : "Failed"
            if let exitCode = card.exitCode {
                line += " (exit \(exitCode))"
            }
            if let text = runner.liveRuns[card.id]?.resultText {
                line += " — \(text)"
            }
            return line
        case .queued, .dispatched, .running:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            promptSection
            if !paramSpecs.isEmpty {
                paramsSection
            }
            controls
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !displayLog.isEmpty {
                logSection
            }
            if let resultSummary {
                Label(resultSummary, systemImage: card.status == .succeeded ? "checkmark.circle" : "xmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(card.status.chipForeground)
            }
            transcriptSection
        }
        .onAppear(perform: syncFromCard)
        .onChange(of: card.prompt) { syncFromCard() }
        .onChange(of: card.paramsJSON) { syncFromCard() }
    }

    private func syncFromCard() {
        if promptDraft != card.prompt { promptDraft = card.prompt }
        let stored = (try? QueueParams.decode(card.paramsJSON)) ?? [:]
        if params != stored { params = stored }
    }

    // MARK: Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $promptDraft)
                .font(.body)
                .frame(minHeight: 64, maxHeight: 140)
                .disabled(!isEditable)
                .foregroundStyle(isEditable ? .primary : .secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                )
                .onChange(of: promptDraft) {
                    guard isEditable, promptDraft != card.prompt else { return }
                    let text = promptDraft
                    Task { await save { try await model.updatePrompt(id: card.id, to: text) } }
                }
        }
    }

    // MARK: Params

    private var paramsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paramSpecs) { spec in
                paramRow(spec)
            }
        }
    }

    @ViewBuilder
    private func paramRow(_ spec: DispatcherParamSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.required ? "\(spec.label) (required)" : spec.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch spec.kind {
            case .directory:
                directoryField(spec)
            case .string:
                TextField(spec.label, text: paramBinding(spec.id))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEditable)
            case .choice(let options):
                Picker(spec.label, selection: defaultedBinding(spec)) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!isEditable)
            case .integer(let range):
                TextField(spec.defaultValue ?? "", text: integerBinding(spec, range: range))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .disabled(!isEditable)
            }
        }
    }

    private func directoryField(_ spec: DispatcherParamSpec) -> some View {
        HStack(spacing: 6) {
            TextField("~/path/to/project", text: paramBinding(spec.id))
                .textFieldStyle(.roundedBorder)
                .disabled(!isEditable)
            Menu {
                let recents = RecentDirs.list()
                if recents.isEmpty {
                    Text("No recent folders")
                } else {
                    ForEach(recents, id: \.self) { dir in
                        Button(dir) { setParam(spec.id, to: dir) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .fixedSize()
            .disabled(!isEditable)
            Button {
                pickDirectory(for: spec.id)
            } label: {
                Image(systemName: "folder")
            }
            .disabled(!isEditable)
        }
    }

    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { params[key] ?? "" },
            set: { setParam(key, to: $0) }
        )
    }

    /// Reads through to the spec default so pickers preselect it; an explicit
    /// selection then writes the value to the card.
    private func defaultedBinding(_ spec: DispatcherParamSpec) -> Binding<String> {
        Binding(
            get: { params[spec.id] ?? spec.defaultValue ?? "" },
            set: { setParam(spec.id, to: $0) }
        )
    }

    private func integerBinding(_ spec: DispatcherParamSpec, range: ClosedRange<Int>) -> Binding<String> {
        Binding(
            get: { params[spec.id] ?? spec.defaultValue ?? "" },
            set: { setParam(spec.id, to: QueueLogic.sanitizedIntegerInput($0, range: range)) }
        )
    }

    private func setParam(_ key: String, to value: String) {
        guard isEditable else { return }
        guard params[key] ?? "" != value else { return }
        params[key] = value
        let updated = params
        Task { await save { try await model.updateParams(id: card.id, to: updated) } }
    }

    private func pickDirectory(for key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            RecentDirs.remember(url.path)
            setParam(key, to: url.path)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            if card.status == .queued {
                Button("Dispatch") {
                    if let dir = params[QueueParams.workingDirectoryKey], !dir.isEmpty {
                        RecentDirs.remember(dir)
                    }
                    Task {
                        await save { try await runner.dispatch(cardID: card.id) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canDispatch)
            }
            if card.status == .dispatched || card.status == .running {
                Button("Cancel", role: .destructive) {
                    runner.cancel(cardID: card.id)
                }
            }
            if card.status == .failed {
                Button("Retry") {
                    Task { await save { try await model.retry(id: card.id) } }
                }
            }
            if card.status.isTerminal, card.sessionID != nil {
                Button("Follow up") {
                    Task { await save { try await model.followUp(from: card) } }
                }
                .help("New card that resumes this run's session")
            }
            Spacer()
            if card.status != .dispatched && card.status != .running {
                Button("Delete", role: .destructive) {
                    Task { await save { try await model.delete(id: card.id) } }
                }
            }
        }
    }

    private func save(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let openLog {
                    Button("Open Full Log") { openLog(card) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            logScroll
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(displayLog)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                Color.clear
                    .frame(height: 1)
                    .id("logEnd")
            }
            .frame(height: 160)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: displayLog) {
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }

    // MARK: Raw transcript

    private var transcriptSection: some View {
        DisclosureGroup {
            Text(card.rawTranscript)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("Raw transcript")
                    .font(.caption.weight(.semibold))
                Text(QueueLogic.refinementBadge(refinedByLLM: card.refinedByLLM))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (card.refinedByLLM ? Color.purple : Color.gray).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(card.refinedByLLM ? Color.purple : Color.secondary)
            }
        }
    }
}
