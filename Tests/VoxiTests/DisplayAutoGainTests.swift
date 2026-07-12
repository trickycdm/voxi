import Testing
@testable import Voxi

@Suite("DisplayAutoGain")
struct DisplayAutoGainTests {
    /// Feed a constant level n times, returning the last display value.
    private func settle(_ gain: inout DisplayAutoGain, level: Float, samples: Int) -> Float {
        var out: Float = 0
        for _ in 0..<samples { out = gain.process(level) }
        return out
    }

    @Test func quietSpeechConvergesTowardTarget() {
        var g = DisplayAutoGain()
        // -38 dBFS-ish talker: raw level ~0.15 would render near-flat bars.
        let display = settle(&g, level: 0.15, samples: 300)
        #expect(display > 0.5)
        #expect(display <= 0.62)
    }

    @Test func normalSpeechIsUntouched() {
        var g = DisplayAutoGain()
        // Raw level already at/above target: desired gain is 1.
        let display = settle(&g, level: 0.65, samples: 300)
        #expect(abs(display - 0.65) < 0.01)
        #expect(abs(g.gain - 1) < 0.01)
    }

    @Test func loudInputAfterQuietRecoversFast() {
        var g = DisplayAutoGain()
        _ = settle(&g, level: 0.15, samples: 300)
        #expect(g.gain > 3)
        // Speaker leans in: within ~1/3 s (10 samples at 30 Hz) gain must collapse.
        let display = settle(&g, level: 0.9, samples: 10)
        #expect(g.gain < 1.5)
        // Output is always clamped, never over-range.
        #expect(display <= 1)
    }

    @Test func silenceDoesNotWindUpGain() {
        var g = DisplayAutoGain()
        _ = settle(&g, level: 0.02, samples: 300)
        #expect(abs(g.gain - 1) < 0.001)
        #expect(g.process(0) == 0)
    }

    @Test func gainStaysWithinClampBounds() {
        var g = DisplayAutoGain()
        _ = settle(&g, level: 0.06, samples: 1000)
        #expect(g.gain <= 4)
        _ = settle(&g, level: 1.0, samples: 1000)
        #expect(g.gain >= 1)
    }

    @Test func resetRestoresUnityGain() {
        var g = DisplayAutoGain()
        _ = settle(&g, level: 0.15, samples: 300)
        #expect(g.gain > 1)
        g.reset()
        #expect(g.gain == 1)
        #expect(g.process(0.65) == 0.65)
    }
}
