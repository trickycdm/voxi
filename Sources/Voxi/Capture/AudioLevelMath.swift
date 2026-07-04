import Accelerate
import Foundation

/// Pure level math shared by the capture pipeline, the hallucination guard,
/// and the waveform UI. Separated for unit testing.
enum AudioLevelMath {
    /// Peak absolute sample value. 0 for empty input.
    static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.maximumMagnitude(samples)
    }

    /// Root mean square. 0 for empty input.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    /// dB range mapped onto the 0...1 waveform level. -50 dBFS (background
    /// noise on a decent mic) maps to 0; -6 dBFS (loud speech) maps to 1.
    static let levelFloorDB: Float = -50
    static let levelCeilingDB: Float = -6

    /// Normalize an RMS value to 0...1 for driving the waveform UI.
    /// Logarithmic (dB) mapping so quiet speech is still visible.
    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let level = (db - levelFloorDB) / (levelCeilingDB - levelFloorDB)
        return min(1, max(0, level))
    }
}

extension CapturedAudio {
    /// Build a capture from raw 16 kHz mono samples, computing level stats.
    init(samples: [Float]) {
        self.init(
            samples: samples,
            peakLevel: AudioLevelMath.peak(samples),
            rmsLevel: AudioLevelMath.rms(samples)
        )
    }
}
