import Foundation
import Observation
import os

let voxiLog = Logger(subsystem: "com.colin.voxi", category: "app")

/// Central coordinator. Owns the module controllers and routes events between
/// them (hotkey → capture → transcription → refinement → insertion/queue).
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

    private(set) var coordinator: DictationCoordinator?
    private var eventTask: Task<Void, Never>?

    /// Latest pill-facing state; the pill controller (shell) observes this
    /// through the coordinator hook once wired.
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

            Task {
                let reconciled = (try? await cards.reconcileInterrupted()) ?? 0
                if reconciled > 0 {
                    voxiLog.notice("Reconciled \(reconciled) interrupted card(s) to failed")
                }
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
}
