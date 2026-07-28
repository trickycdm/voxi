import SwiftUI

/// Card detail, per the Rev A board (now the Queue pane's right-hand column):
/// prompt well, context chips (folder + resume-session), two dispatch-time
/// action buttons, advanced disclosure for the headless-only knobs, live log,
/// result summary, and the raw-transcript disclosure with its refinement
/// badge. Hosted with `.id(card.id)` so drafts re-seed per selection.
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
    @State private var advancedExpanded = false

    private var isEditable: Bool { card.status == .queued }

    /// One card face regardless of the stored dispatcherID: the union of
    /// every registered dispatcher's specs (the button pressed picks the
    /// dispatcher at dispatch time).
    private var combinedSpecs: [DispatcherParamSpec] {
        QueueLogic.combinedSpecs(resolver.allDispatchers.map(\.paramSpecs))
    }

    private var advancedSpecs: [DispatcherParamSpec] {
        combinedSpecs.filter { $0.placement == .advanced }
    }

    private var workingDirectory: String {
        (params[QueueParams.workingDirectoryKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Set but pointing nowhere — cheap view-level check; the dispatcher's
    /// own existence check at execute remains the real gate.
    private var directoryMissingOnDisk: Bool {
        !workingDirectory.isEmpty && !FileManager.default.fileExists(atPath: workingDirectory)
    }

    private var canDispatch: Bool {
        QueueLogic.canDispatch(status: card.status, prompt: promptDraft, params: params, specs: combinedSpecs)
            && !directoryMissingOnDisk
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
            promptWell
            contextChips
            controls
            if isEditable, !advancedSpecs.isEmpty {
                advancedSection
            }
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(Color.voxiDanger)
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

    /// Inset well, separated by tone (no stroke). Locked cards render plain
    /// selectable text in the identical well — a disabled TextEditor would
    /// block copying the prompt of a finished run.
    @ViewBuilder
    private var promptWell: some View {
        if isEditable {
            TextEditor(text: $promptDraft)
                .font(.body)
                .foregroundStyle(Color.voxiInk)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.sm)
                .frame(minHeight: 64, maxHeight: 280)
                .background(Color.voxiInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .onChange(of: promptDraft) {
                    guard isEditable, promptDraft != card.prompt else { return }
                    let text = promptDraft
                    Task { await save { try await model.updatePrompt(id: card.id, to: text) } }
                }
        } else {
            Text(card.prompt)
                .font(.body)
                .foregroundStyle(Color.voxiInk2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.sm)
                .background(Color.voxiInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
    }

    // MARK: Context chips

    private var contextChips: some View {
        HStack(spacing: Theme.Space.sm) {
            folderChip
            if let session = params[QueueParams.resumeSessionIDKey], !session.isEmpty {
                sessionChip(session)
            }
            Spacer(minLength: 0)
        }
    }

    private var folderProblem: Bool {
        workingDirectory.isEmpty || directoryMissingOnDisk
    }

    /// The working directory as a capsule menu: repo name on the face; full
    /// path, recents, and Browse… inside. Warning styling recolors icon+text
    /// only — the capsule fill stays inset (status colors belong to status).
    private var folderChip: some View {
        Menu {
            if !workingDirectory.isEmpty {
                // Plain Text renders as a disabled item — the full path,
                // since the chip face only shows the last component.
                Text(workingDirectory)
                Divider()
            }
            let recents = RecentDirs.list()
            ForEach(recents, id: \.self) { dir in
                Button(dir) { setParam(QueueParams.workingDirectoryKey, to: dir) }
            }
            if !recents.isEmpty { Divider() }
            Button("Browse…") { pickDirectory(for: QueueParams.workingDirectoryKey) }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: folderProblem ? "exclamationmark.triangle" : "folder")
                    .imageScale(.small)
                Text(workingDirectory.isEmpty
                    ? "Choose folder"
                    : (workingDirectory as NSString).lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isEditable {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(Color.voxiInk3)
                }
            }
            .padding(.horizontal, Theme.Space.sm + 2)
            .padding(.vertical, 4)
            .foregroundStyle(folderProblem ? Color.voxiWarning : Color.voxiInk2)
            .background(Color.voxiInset, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 260, alignment: .leading)
        .disabled(!isEditable)
        .help(workingDirectory.isEmpty ? "Choose the folder claude runs in" : workingDirectory)
    }

    /// Only exists on follow-up cards (the param is plumbing, never typed).
    /// Dashed hairline is deliberate: tone can't say "derived state".
    private func sessionChip(_ session: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "arrow.uturn.backward")
                .imageScale(.small)
            Text("resumes session \(String(session.prefix(6)))")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if isEditable {
                Button {
                    clearResumeSession()
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(Color.voxiInk3)
                }
                .buttonStyle(.plain)
                .help("Detach from the previous session")
            }
        }
        .padding(.horizontal, Theme.Space.sm + 2)
        .padding(.vertical, 4)
        .foregroundStyle(Color.voxiInk2)
        .overlay(
            Capsule().strokeBorder(
                Color.voxiHairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .fixedSize()
    }

    private func clearResumeSession() {
        guard isEditable else { return }
        var updated = params
        updated.removeValue(forKey: QueueParams.resumeSessionIDKey)
        params = updated
        Task { await save { try await model.updateParams(id: card.id, to: updated) } }
    }

    // MARK: Advanced (headless-only knobs, closed by default)

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(advancedSpecs) { spec in
                    paramRow(spec)
                }
            }
            .padding(.top, Theme.Space.xs)
        } label: {
            Text("Advanced — headless options")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.voxiInk3)
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

    /// Fallback row for future dispatchers that spec an advanced directory —
    /// the union's primary directory renders as the folder chip instead.
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
                Button("Open in iTerm") {
                    dispatchTapped(as: ClaudeCodeITermDispatcher.dispatcherID)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canDispatch)
                Button("Run Headless") {
                    dispatchTapped(as: ClaudeCodeDispatcher.dispatcherID)
                }
                .buttonStyle(.bordered)
                .disabled(!canDispatch)
                // Two cards once sat stuck queued because nothing said why
                // the buttons were grey — always name the blocker.
                if let blocker = dispatchBlockerText {
                    Text(blocker)
                        .font(.callout)
                        .foregroundStyle(Color.voxiInk3)
                }
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
                Button("Open in iTerm") { openResumeInTerminal() }
                    .help("Resume this run's session interactively (Terminal if iTerm isn't installed)")
                    .disabled(resumeWorkingDirectory == nil)
                Button("Follow up") {
                    Task { await save { try await model.followUp(from: card) } }
                }
                .help("New card that resumes this run's session")
            }
            Spacer()
            if card.status != .dispatched && card.status != .running {
                Button("Delete") {
                    Task { await save { try await model.delete(id: card.id) } }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.voxiInk3)
            }
        }
    }

    private var dispatchBlockerText: String? {
        if let blocker = QueueLogic.dispatchBlocker(
            status: card.status, prompt: promptDraft, params: params, specs: combinedSpecs
        ) {
            return blocker
        }
        if directoryMissingOnDisk {
            return "Folder doesn't exist"
        }
        return nil
    }

    /// The dispatch button pressed picks the dispatcher; the choice is
    /// recorded atomically with queued → dispatched by the runner.
    private func dispatchTapped(as dispatcherID: String) {
        if !workingDirectory.isEmpty {
            RecentDirs.remember(workingDirectory)
        }
        Task { await save { try await runner.dispatch(cardID: card.id, as: dispatcherID) } }
    }

    /// The card's working directory, when usable for an interactive resume.
    private var resumeWorkingDirectory: String? {
        workingDirectory.isEmpty ? nil : workingDirectory
    }

    /// Fire-and-forget UI convenience, not card lifecycle — the queue's
    /// record of the run is untouched; errors land in `lastError`.
    private func openResumeInTerminal() {
        guard let sessionID = card.sessionID, let dir = resumeWorkingDirectory else { return }
        Task {
            // locate() shells out to `claude --version`; keep it off the main thread.
            guard let binary = await Task.detached(operation: { ClaudeBinaryLocator().locate() }).value else {
                lastError = "claude CLI (\(ClaudeBinaryLocator.requiredMajorVersion).x or newer) not found"
                return
            }
            let command = TerminalLauncher.resumeCommand(
                claudePath: binary.path, workingDirectory: dir, sessionID: sessionID)
            do {
                try TerminalLauncher.launch(command: command)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
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
            .frame(height: 280)
            // VoxiInset adapts per appearance — the old .black.opacity(0.05)
            // was invisible against dark backgrounds.
            .background(Color.voxiInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
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
                        (card.refinedByLLM ? Color.accentColor : Color.voxiInk3).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(card.refinedByLLM ? Color.accentColor : Color.voxiInk2)
            }
        }
    }
}
