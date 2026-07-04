import Foundation
import Observation
import os

let voxiLog = Logger(subsystem: "com.colin.voxi", category: "app")

/// Central coordinator. Owns the module controllers and routes events between
/// them (hotkey → capture → transcription → refinement → insertion/queue).
@MainActor
@Observable
final class AppState {
    // Wired up as milestones land; kept minimal so the skeleton builds.

    func start() {
        voxiLog.info("Voxi starting")
    }

    func shutdown() {
        voxiLog.info("Voxi shutting down")
    }
}
