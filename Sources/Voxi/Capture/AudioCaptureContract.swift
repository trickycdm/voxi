import Foundation

/// A finished capture: 16 kHz mono Float32 samples plus level stats for the
/// hallucination guard.
struct CapturedAudio: Sendable {
    var samples: [Float]
    var duration: TimeInterval { Double(samples.count) / 16_000 }
    /// Peak absolute sample value over the whole capture.
    var peakLevel: Float
    /// RMS over the whole capture.
    var rmsLevel: Float

    /// Heuristic: true when the audio is likely silence/noise that Whisper-class
    /// models hallucinate on. Thresholds unit-tested in SignalGuardTests.
    var isLikelySilence: Bool {
        SignalGuard.isLikelySilence(peak: peakLevel, rms: rmsLevel, duration: duration)
    }
}

/// Pure threshold logic, separated for unit testing.
enum SignalGuard {
    static let peakThreshold: Float = 0.015
    static let rmsThreshold: Float = 0.004

    static func isLikelySilence(peak: Float, rms: Float, duration: TimeInterval) -> Bool {
        if duration < 0.35 { return true }          // too short to contain speech
        return peak < peakThreshold || rms < rmsThreshold
    }
}

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String        // unique device UID
    let name: String
    let isDefault: Bool
}
