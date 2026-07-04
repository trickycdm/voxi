import AVFAudio
import Foundation

/// Accumulates one capture's audio. `ingest` is called on AVAudioEngine's
/// realtime tap thread; everything else on the main actor — an unfair lock
/// serializes them (tap callbacks are already off the true audio IO thread,
/// so a briefly-held lock is safe here).
///
/// Buffers are converted to 16 kHz mono Float32 as they arrive and the
/// AVAudioPCMBuffer never escapes the tap callback, which sidesteps its
/// non-Sendability under strict concurrency.
final class CaptureSession: @unchecked Sendable {
    /// Minimum interval between level-callback emissions (~30 Hz).
    static let levelInterval: TimeInterval = 1.0 / 30.0

    private let lock = NSLock()
    private var resampler: StreamResampler
    private var samples: [Float] = []
    private var finished = false
    private var lastLevelEmit: TimeInterval = 0
    private let onLevel: @Sendable (Float) -> Void

    init(inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        self.resampler = try StreamResampler(inputFormat: inputFormat)
        self.onLevel = onLevel
    }

    /// Called from the realtime tap thread with each incoming buffer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let chunk = resampler.process(buffer)
        guard !chunk.isEmpty else { return }
        samples.append(contentsOf: chunk)

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelEmit >= Self.levelInterval {
            lastLevelEmit = now
            onLevel(AudioLevelMath.normalizedLevel(rms: AudioLevelMath.rms(chunk)))
        }
    }

    /// The input format changed mid-capture (device switch / config change).
    /// Drains the old converter's tail and continues with a new one; if the
    /// new format is unconvertible, the session keeps what it has.
    func switchInputFormat(_ format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        samples.append(contentsOf: resampler.flush())
        do {
            resampler = try StreamResampler(inputFormat: format)
        } catch {
            finished = true
            voxiLog.warning("capture: unconvertible input format after config change; keeping audio so far")
        }
    }

    /// Drain the converter tail and return the finished capture. Idempotent.
    func finish() -> CapturedAudio {
        lock.lock()
        defer { lock.unlock() }
        if !finished {
            finished = true
            samples.append(contentsOf: resampler.flush())
        }
        return CapturedAudio(samples: samples)
    }
}
