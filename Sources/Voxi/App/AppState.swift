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
    private(set) var queueWindow: QueueWindowController?
    private(set) var logWindows: LogWindowController?

    private var eventTask: Task<Void, Never>?
    /// Display-only auto-gain for the pill waveform (see DisplayAutoGain).
    @ObservationIgnored private var pillGain = DisplayAutoGain()

    private(set) var lastError: String?

    func start() {
        voxiLog.info("Voxi starting")
        do {
            let db = try AppDatabase()
            database = db
            let history = HistoryStore(database: db)
            let dictionary = DictionaryStore(database: db)
            let cards = CardStore(database: db)
            historyStore = history
            dictionaryStore = dictionary
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

            let resolver = RegistryResolver(registry: DispatcherRegistry.v1())
            let model = QueueModel(store: cards)
            let runner = QueueRunner(store: cards, resolver: resolver)
            queueModel = model
            queueRunner = runner
            let logWindows = LogWindowController(model: model, runner: runner)
            self.logWindows = logWindows
            queueWindow = QueueWindowController(
                model: model, runner: runner, resolver: resolver,
                openLog: { [logWindows] card in logWindows.show(card: card) })
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
    }

    func shutdown() {
        voxiLog.info("Voxi shutting down")
        eventTask?.cancel()
        hotkeys.stop()
    }

    /// Show the queue window (menu bar + command-card notice both land here).
    func openQueue() {
        queueWindow?.show()
    }

    // MARK: - Queue alerts

    /// A queued card opens the queue for review; a finished run raises a
    /// pill notice + system notification. Authorization is requested the
    /// first time a card is queued (contextual), never at launch.
    private func wireQueueAlerts(coordinator: DictationCoordinator, runner: QueueRunner, cards: CardStore) {
        notifications.activate()
        notifications.onOpen = { [weak self] in self?.openQueue() }
        coordinator.onCardQueued = { [weak self] _ in
            guard let self else { return }
            self.notifications.requestAuthorizationIfNeeded()
            self.openQueue()
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

    private func wirePill(coordinator: DictationCoordinator) {
        coordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .recording = state { self.pillGain.reset() }
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
}
