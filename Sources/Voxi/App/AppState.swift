import AppKit
import Foundation
import Observation
import os

let voxiLog = Logger(subsystem: "com.colin.voxi", category: "app")

/// Central coordinator. Owns the module controllers and routes events between
/// them (hotkey → capture → transcription → refinement → insertion/queue),
/// and fans state out to the pill and queue UI.
@MainActor
@Observable
final class AppState {
    private(set) var database: AppDatabase?
    private(set) var historyStore: HistoryStore?
    private(set) var dictionaryStore: DictionaryStore?
    private(set) var learnedCorrectionStore: LearnedCorrectionStore?
    private(set) var cardStore: CardStore?

    let registry = ASREngineRegistry(engines: ASREngineRegistry.makeDefaultEngines())
    let capture = AudioCapture()
    let inserter = TextInserter()
    let hotkeys = HotkeyController()
    let pill = PillController()
    let notifications = NotificationPresenter()

    private(set) var coordinator: DictationCoordinator?
    private(set) var queueModel: QueueModel?
    private(set) var queueRunner: QueueRunner?
    private(set) var dispatcherResolver: (any DispatcherResolving)?
    private(set) var hubWindow: HubWindowController?
    private(set) var logWindows: LogWindowController?

    private var eventTask: Task<Void, Never>?
    /// Post-insert correction learning (created in start(), lives app-long).
    @ObservationIgnored private var postInsertObserver: PostInsertObserver?
    /// Display-only auto-gain for the pill waveform (see DisplayAutoGain).
    @ObservationIgnored private var pillGain = DisplayAutoGain()

    private(set) var lastError: String?

    func start(updater: UpdaterController) {
        voxiLog.info("Voxi starting")
        hubWindow = HubWindowController(appState: self, updater: updater)
        do {
            let db = try AppDatabase()
            database = db
            let history = HistoryStore(database: db)
            let dictionary = DictionaryStore(database: db)
            let learned = LearnedCorrectionStore(database: db)
            let cards = CardStore(database: db)
            historyStore = history
            dictionaryStore = dictionary
            learnedCorrectionStore = learned
            cardStore = cards

            let coordinator = DictationCoordinator(
                capture: capture,
                registry: registry,
                inserter: inserter,
                historyStore: history,
                dictionaryStore: dictionary,
                cardStore: cards
            )
            self.coordinator = coordinator
            wireCorrectionLearning(coordinator: coordinator, dictionary: dictionary, learned: learned)

            let resolver = RegistryResolver(registry: DispatcherRegistry.v1())
            let model = QueueModel(store: cards)
            let runner = QueueRunner(store: cards, resolver: resolver)
            queueModel = model
            queueRunner = runner
            dispatcherResolver = resolver
            logWindows = LogWindowController(model: model, runner: runner)
            model.startObserving()

            wirePill(coordinator: coordinator)
            wireQueueAlerts(coordinator: coordinator, runner: runner, cards: cards)

            Task {
                let reconciled = (try? await cards.reconcileInterrupted()) ?? 0
                if reconciled > 0 {
                    voxiLog.notice("Reconciled \(reconciled) interrupted card(s) to failed")
                }
                try? await model.load()
            }
        } catch {
            lastError = "Database unavailable: \(error.localizedDescription)"
            voxiLog.fault("AppDatabase init failed: \(error.localizedDescription)")
        }

        hotkeys.start()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkeys.events {
                self.coordinator?.handle(event, hotkeys: self.hotkeys)
            }
        }

        // Prewarm the selected ASR engine so the first dictation isn't slow.
        Task { [registry] in
            do {
                _ = try await registry.loadSelected()
                voxiLog.info("ASR engine prewarmed")
            } catch {
                voxiLog.notice("ASR prewarm skipped: \(error.localizedDescription)")
            }
        }

        // Same for the on-device refiner model (1-3 s load otherwise paid on
        // the first dictation).
        let refinerConfig = RefinerConfig.load()
        if refinerConfig.backend == .localLLM {
            Task {
                do {
                    try await LocalLLMEngine.shared.ensureLoaded(modelID: refinerConfig.localModelID)
                    voxiLog.info("on-device refiner prewarmed")
                } catch {
                    voxiLog.notice("on-device refiner prewarm skipped: \(error.localizedDescription)")
                }
            }
        }
    }

    func shutdown() {
        voxiLog.info("Voxi shutting down")
        eventTask?.cancel()
        hotkeys.stop()
    }

    /// Show the Hub window, optionally deep-linked to a section and — for the
    /// queue — a specific card (menu bar + notification taps both land here).
    func openHub(section: HubSection? = nil, revealCard cardID: UUID? = nil) {
        hubWindow?.show(section: section, revealCard: cardID)
    }

    // MARK: - Queue alerts

    /// A queued card raises a pill notice + system notification (no window
    /// steal); a finished run does the same. Notification taps deep-link to
    /// the Hub's queue pane. Authorization is requested the first time a card
    /// is queued (contextual), never at launch.
    private func wireQueueAlerts(coordinator: DictationCoordinator, runner: QueueRunner, cards: CardStore) {
        notifications.activate()
        notifications.onOpen = { [weak self] cardID in
            self?.openHub(section: .queue, revealCard: cardID)
        }
        coordinator.onCardQueued = { [weak self] card in
            guard let self else { return }
            let id = card.id
            let title = card.title
            self.notifications.requestAuthorizationIfNeeded { [weak self] in
                self?.notifications.postCardQueued(cardID: id, cardTitle: title)
            }
        }
        runner.onRunFinished = { [weak self] cardID, success, resultText in
            guard let self else { return }
            Task { @MainActor in
                let card = (try? await cards.fetch(id: cardID)) ?? nil
                let title = card?.title ?? "Task"
                self.pill.showNotice(success ? "✓ \(title) succeeded" : "✗ \(title) failed")
                self.notifications.postRunFinished(
                    cardID: cardID, cardTitle: title, success: success, resultText: resultText)
            }
        }
    }

    // MARK: - Pill wiring

    /// Post-paste correction learning: after a dictation lands, watch the
    /// target field briefly and fold a narrow wrong→right fix into the
    /// personal dictionary (term = the corrected word, variant = what we
    /// inserted). Gated by the "Learn corrections" setting at fire time so a
    /// toggle takes effect immediately.
    private func wireCorrectionLearning(
        coordinator: DictationCoordinator, dictionary: DictionaryStore,
        learned: LearnedCorrectionStore
    ) {
        let observer = PostInsertObserver(
            readField: {
                guard let element = AXFocus.frontmostTarget()?.element else { return nil }
                return AXFocus.fullText(of: element)
            },
            readFrontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        )
        observer.onLearnedCorrection = { [weak self] correction in
            self?.storeLearnedCorrection(correction, dictionary: dictionary, learned: learned)
        }
        postInsertObserver = observer
        coordinator.onInserted = { [weak self] insertedText, targetBundleID in
            guard let self, self.inserter.settings.learnCorrections else { return }
            self.postInsertObserver?.begin(
                insertedText: insertedText, targetBundleID: targetBundleID)
        }
    }

    private func storeLearnedCorrection(
        _ correction: CorrectionInference.Correction, dictionary: DictionaryStore,
        learned: LearnedCorrectionStore
    ) {
        Task {
            // Log first (feeds the Hub's "Learned Corrections" list): the
            // variant below may already exist — e.g. the pair was learned
            // before the log table shipped — and that path returns early.
            try? await learned.upsert(LearnedCorrection(
                wrong: correction.wrong, right: correction.right))
            let entries = (try? await dictionary.all()) ?? []
            if var existing = entries.first(where: {
                $0.term.caseInsensitiveCompare(correction.right) == .orderedSame
            }) {
                guard !existing.variants.contains(where: {
                    $0.caseInsensitiveCompare(correction.wrong) == .orderedSame
                }) else { return }
                existing.variants.append(correction.wrong)
                try? await dictionary.upsert(existing)
            } else {
                try? await dictionary.upsert(DictionaryEntry(
                    term: correction.right, variants: [correction.wrong], createdAt: Date()))
            }
            // Never log the learned content — only that learning happened.
            voxiLog.info("post-insert learning stored a dictionary correction")
        }
    }

    private func wirePill(coordinator: DictationCoordinator) {
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .recording = state {
                self.pillGain.reset()
                self.pill.activeInputName = InputDeviceNaming.resolvedName(
                    uid: UserDefaults.standard.string(forKey: "audio.inputDeviceUID"),
                    devices: AudioCapture.listInputDevices())
            }
            self.pill.transition(to: state)
        }
        capture.onLevel = { [weak self] level in
            guard let self else { return }
            self.pill.level = self.pillGain.process(level)
        }
        // The pill's ✕/✓ mirror Esc and chord-release respectively. Ending a
        // session from the mouse leaves the keyboard-side chord state (e.g. a
        // toggle latch) dangling — reset it so Esc isn't swallowed afterwards.
        pill.onCancel = { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.handle(.cancel, hotkeys: self.hotkeys)
            self.hotkeys.resetChordState()
        }
        pill.onDone = { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.handle(.actionEnded(.pushToTalk), hotkeys: self.hotkeys)
            self.hotkeys.resetChordState()
        }
    }
}

/// Adapts the Dispatchers module's registry to the CommandQueue's resolver protocol.
private struct RegistryResolver: DispatcherResolving {
    let registry: DispatcherRegistry
    func dispatcher(for id: String) -> (any Dispatcher)? {
        registry.dispatcher(id: id)
    }
    var allDispatchers: [any Dispatcher] { registry.all }
}
