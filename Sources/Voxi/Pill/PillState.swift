import Foundation

/// The pill's single source of truth. Every visual state derives from this;
/// transitions go through PillController so the panel can never be stranded.
enum PillState: Equatable, Sendable {
    case idle
    /// level: live input level 0...1 for the waveform.
    case recording(mode: RecordingMode, level: Float)
    case processing
    /// Transient error/notice bubble (e.g. "Mic level too low"), auto-dismissed.
    case notice(String)

    enum RecordingMode: Equatable, Sendable {
        case dictation
        case command
    }
}
