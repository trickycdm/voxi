import AppKit
import Foundation

/// Runs one voice session end-to-end: capture → transcribe → refine →
/// insert (dictation) or enqueue a card (command). Owned by AppState; kept
/// separate so the pipeline is readable in one place.
@MainActor
final class DictationCoordinator {
    enum SessionKind: Equatable {
        case dictation
        case command
    }

    /// Non-nil while audio is being captured.
    private(set) var activeSession: SessionKind?

    private let capture: AudioCapture
    private let registry: ASREngineRegistry
    private let inserter: TextInserter
    private let historyStore: HistoryStore
    private let dictionaryStore: DictionaryStore
    private let cardStore: CardStore

    /// Personal dictionary snapshot, refreshed when a session starts.
    private var dictionaryTerms: [DictionaryTerm] = []

    /// Hooks the shell (pill / menu bar) attaches to. All optional so the
    /// pipeline works headless.
    var onStateChange: ((PillState) -> Void)?
    var onCardQueued: ((ActionCard) -> Void)?

    init(
        capture: AudioCapture,
        registry: ASREngineRegistry,
        inserter: TextInserter,
        historyStore: HistoryStore,
        dictionaryStore: DictionaryStore,
        cardStore: CardStore
    ) {
        self.capture = capture
        self.registry = registry
        self.inserter = inserter
        self.historyStore = historyStore
        self.dictionaryStore = dictionaryStore
        self.cardStore = cardStore
    }

    // MARK: - Hotkey event entry point

    func handle(_ event: HotkeyEvent, hotkeys: HotkeyController) {
        switch event {
        case .actionBegan(let action):
            let kind: SessionKind = (action == .commandMode) ? .command : .dictation
            if activeSession != nil {
                // Retarget convention from ChordStateMachine: a new actionBegan
                // while capturing means the same audio continues under the new kind
                // (Fn PTT upgraded to Fn+Ctrl command, or latched by Fn+Space).
                activeSession = kind
                onStateChange?(.recording(mode: kind.pillMode, level: 0))
                return
            }
            beginSession(kind, hotkeys: hotkeys)

        case .actionEnded:
            guard activeSession != nil else { return }
            finishSession(hotkeys: hotkeys)

        case .cancel, .aborted:
            guard activeSession != nil else { return }
            cancelSession(hotkeys: hotkeys)
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(_ kind: SessionKind, hotkeys: HotkeyController) {
        do {
            try capture.start(deviceUID: UserDefaults.standard.string(forKey: "audio.inputDeviceUID"))
        } catch {
            voxiLog.error("Capture failed to start: \(error.localizedDescription)")
            onStateChange?(.notice("Microphone unavailable"))
            return
        }
        activeSession = kind
        hotkeys.sessionActive = true
        // Physical confirmation the mic is hot; no-op without a Force Touch trackpad.
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        onStateChange?(.recording(mode: kind.pillMode, level: 0))
        Task { [weak self] in
            guard let self else { return }
            self.dictionaryTerms = await self.loadDictionaryTerms()
        }
    }

    private func cancelSession(hotkeys: HotkeyController) {
        capture.cancel()
        activeSession = nil
        hotkeys.sessionActive = false
        onStateChange?(.idle)
        voxiLog.info("Dictation cancelled")
    }

    private func finishSession(hotkeys: HotkeyController) {
        guard let kind = activeSession else { return }
        activeSession = nil
        onStateChange?(.processing)

        // Capture the insertion target *before* any await: the user may switch
        // apps while we transcribe, but the text belongs where they dictated it.
        let targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        Task { [weak self] in
            guard let self else { return }
            let audio = await self.capture.stop()
            hotkeys.sessionActive = false
            await self.process(audio: audio, kind: kind, targetApp: targetApp)
        }
    }

    private func process(audio: CapturedAudio, kind: SessionKind, targetApp: String?) async {
        guard !audio.isLikelySilence else {
            voxiLog.notice("Discarding capture: likely silence (peak \(audio.peakLevel), rms \(audio.rmsLevel))")
            onStateChange?(.notice("No speech detected — check your microphone"))
            return
        }

        let terms = dictionaryTerms
        let vocabulary = terms.map(\.canonical)

        do {
            let engine = try await registry.loadSelected()
            let hints = TranscriptionHints(vocabulary: vocabulary)
            let raw = try await engine.transcribe(samples: audio.samples, hints: hints)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onStateChange?(.notice("Nothing transcribed"))
                return
            }

            let chain = RefinerChain(config: .load(), dictionary: { terms })
            let modelID = registry.selectedModelID(for: engine.id) ?? ""

            switch kind {
            case .dictation:
                let outcome = await chain.refine(
                    trimmed,
                    context: RefinementContext(mode: .dictation, vocabulary: vocabulary)
                )
                let inserted = try await inserter.insert(outcome.text)
                onStateChange?(.idle)
                try await historyStore.save(HistoryEntry(
                    rawTranscript: trimmed,
                    finalText: inserted.insertedText,
                    engineID: engine.id,
                    modelID: modelID,
                    refinerID: outcome.refinerID,
                    targetAppBundleID: targetApp,
                    durationSeconds: audio.duration
                ))

            case .command:
                let outcome = await chain.refineCard(
                    from: trimmed,
                    context: RefinementContext(mode: .command, vocabulary: vocabulary)
                )
                let card = ActionCard(
                    title: outcome.draft.title,
                    summary: outcome.draft.summary,
                    prompt: outcome.draft.prompt,
                    rawTranscript: trimmed,
                    refinedByLLM: outcome.draft.refinedByLLM,
                    dispatcherID: "claude-code",
                    paramsJSON: Self.defaultCardParams()
                )
                try await cardStore.insert(card)
                onStateChange?(.notice("Queued: \(card.title)"))
                onCardQueued?(card)
                try await historyStore.save(HistoryEntry(
                    rawTranscript: trimmed,
                    finalText: card.prompt,
                    engineID: engine.id,
                    modelID: modelID,
                    refinerID: outcome.refinerID,
                    targetAppBundleID: nil,
                    durationSeconds: audio.duration
                ))
            }
        } catch {
            voxiLog.error("Voice session failed: \(error.localizedDescription)")
            onStateChange?(.notice(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private func loadDictionaryTerms() async -> [DictionaryTerm] {
        guard let entries = try? await dictionaryStore.all() else { return [] }
        return entries.map { DictionaryTerm(canonical: $0.term, variants: $0.variants) }
    }

    /// Pre-fill the card's working directory from the recent-dirs MRU so a
    /// card is dispatchable with one click when the user works in one repo.
    private static func defaultCardParams() -> String {
        let recent = UserDefaults.standard.stringArray(forKey: "voxi.recentDirs")?.first ?? ""
        let params = ["workingDirectory": recent]
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

private extension DictationCoordinator.SessionKind {
    var pillMode: PillState.RecordingMode {
        switch self {
        case .dictation: .dictation
        case .command: .command
        }
    }
}
