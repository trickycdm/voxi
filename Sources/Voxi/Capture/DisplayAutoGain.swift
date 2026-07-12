import Foundation

/// Display-only automatic gain for the pill waveform. Tracks a decaying peak
/// of recent normalized levels and slowly boosts a quiet talker's bars toward
/// a comfortable height, pulling back fast when the input gets loud.
///
/// Display only: never feed the output to SignalGuard or the onboarding
/// mic-test gate — both are calibrated against raw levels.
struct DisplayAutoGain {
    /// Display level that recent speech peaks are boosted toward.
    private let target: Float
    /// Rolling peaks at or below this are treated as silence/room noise:
    /// gain holds instead of winding up to amplify the noise floor.
    private let noiseFloor: Float
    private let maxGain: Float
    /// Per-sample smoothing toward a higher gain (slow, ≈2 s to settle at 30 Hz).
    private let attack: Float
    /// Per-sample smoothing toward a lower gain (fast, so loud input stops clipping quickly).
    private let release: Float
    /// Rolling-peak decay per sample.
    private let peakDecay: Float

    private var rollingPeak: Float = 0
    private(set) var gain: Float = 1

    init(
        target: Float = 0.6,
        noiseFloor: Float = 0.05,
        maxGain: Float = 4,
        attack: Float = 0.03,
        release: Float = 0.3,
        peakDecay: Float = 0.985
    ) {
        self.target = target
        self.noiseFloor = noiseFloor
        self.maxGain = maxGain
        self.attack = attack
        self.release = release
        self.peakDecay = peakDecay
    }

    /// Start fresh (call at the start of each capture session).
    mutating func reset() {
        rollingPeak = 0
        gain = 1
    }

    /// Map a raw normalized level (0...1, ~30 Hz) to its display level.
    mutating func process(_ level: Float) -> Float {
        rollingPeak = max(level, rollingPeak * peakDecay)
        if rollingPeak > noiseFloor {
            let desired = min(maxGain, max(1, target / rollingPeak))
            let rate = desired < gain ? release : attack
            gain += (desired - gain) * rate
        }
        return min(1, level * gain)
    }
}
