import AVFAudio
import Foundation
import Testing
@testable import Voxi

// MARK: - Helpers

/// Tests/Fixtures/audio resolved from this source file's location (fixtures
/// are gitignored; regenerate with Scripts/make-test-audio.sh).
private let fixturesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/VoxiTests
    .deletingLastPathComponent()   // Tests
    .appendingPathComponent("Fixtures/audio", isDirectory: true)

private func fixture(_ name: String) throws -> URL {
    let url = fixturesDir.appendingPathComponent(name)
    try #require(
        FileManager.default.fileExists(atPath: url.path),
        "Missing fixture \(name) — run Scripts/make-test-audio.sh")
    return url
}

private func sineSamples(
    frequency: Double, amplitude: Float, sampleRate: Double, seconds: Double
) -> [Float] {
    let count = Int(sampleRate * seconds)
    return (0..<count).map { i in
        amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
    }
}

/// Theoretical RMS of a sine wave with the given amplitude.
private func sineRMS(amplitude: Float) -> Float {
    amplitude / Float(2).squareRoot()
}

private func pcmBuffer(
    samples: [Float], sampleRate: Double, channels: AVAudioChannelCount = 1
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for channel in 0..<Int(channels) {
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![channel].update(from: source.baseAddress!, count: samples.count)
        }
    }
    return buffer
}

// MARK: - Level math

@Suite struct AudioLevelMathTests {
    @Test func sineRMSAndPeak() {
        // For a sine of amplitude A: RMS = A/sqrt(2), peak = A.
        let samples = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: 16_000, seconds: 1)
        #expect(abs(AudioLevelMath.rms(samples) - sineRMS(amplitude: 0.5)) < 0.001)
        #expect(abs(AudioLevelMath.peak(samples) - 0.5) < 0.001)
    }

    @Test func emptyInputIsZero() {
        #expect(AudioLevelMath.rms([]) == 0)
        #expect(AudioLevelMath.peak([]) == 0)
        #expect(AudioLevelMath.normalizedLevel(rms: 0) == 0)
    }

    @Test func normalizedLevelBounds() {
        #expect(AudioLevelMath.normalizedLevel(rms: 1.0) == 1)      // 0 dBFS clamps to 1
        #expect(AudioLevelMath.normalizedLevel(rms: 0.001) == 0)    // -60 dBFS clamps to 0
        let mid = AudioLevelMath.normalizedLevel(rms: 0.05)         // ~-26 dBFS: mid-range
        #expect(mid > 0.3 && mid < 0.8)
    }

    @Test func normalizedLevelIsMonotonic() {
        let levels = [0.002, 0.01, 0.05, 0.2, 0.5].map {
            AudioLevelMath.normalizedLevel(rms: Float($0))
        }
        #expect(levels == levels.sorted())
        #expect(levels.first! < levels.last!)
    }
}

// MARK: - CapturedAudio

@Suite struct CapturedAudioTests {
    @Test func initComputesLevels() {
        let samples = sineSamples(frequency: 200, amplitude: 0.8, sampleRate: 16_000, seconds: 2)
        let audio = CapturedAudio(samples: samples)
        #expect(abs(audio.duration - 2.0) < 0.001)
        #expect(abs(audio.peakLevel - 0.8) < 0.01)
        #expect(abs(audio.rmsLevel - sineRMS(amplitude: 0.8)) < 0.01)
        #expect(!audio.isLikelySilence)
    }

    @Test func zeroLengthCapture() {
        let audio = CapturedAudio(samples: [])
        #expect(audio.duration == 0)
        #expect(audio.peakLevel == 0)
        #expect(audio.rmsLevel == 0)
        #expect(audio.isLikelySilence)
    }
}

// MARK: - Resampler

@Suite struct StreamResamplerTests {
    @Test func downsamples48kMonoPreservingSignal() throws {
        let inputRate = 48_000.0
        let samples = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: inputRate, seconds: 1)
        let resampler = try StreamResampler(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!)

        // Feed in tap-sized chunks like a live capture would.
        var output: [Float] = []
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let chunk = Array(samples[start..<min(start + 1024, samples.count)])
            output += resampler.process(pcmBuffer(samples: chunk, sampleRate: inputRate))
        }
        output += resampler.flush()

        // 1 s of audio -> ~16000 output frames (converter may trim a few edge frames).
        #expect(abs(output.count - 16_000) < 160)
        // 440 Hz is far below Nyquist at 16 kHz; RMS must survive resampling.
        #expect(abs(AudioLevelMath.rms(output) - sineRMS(amplitude: 0.5)) < 0.02)
        #expect(AudioLevelMath.peak(output) < 0.55)
    }

    @Test func downmixesStereo() throws {
        let inputRate = 44_100.0
        let samples = sineSamples(frequency: 300, amplitude: 0.4, sampleRate: inputRate, seconds: 0.5)
        let resampler = try StreamResampler(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false)!)

        var output = resampler.process(pcmBuffer(samples: samples, sampleRate: inputRate, channels: 2))
        output += resampler.flush()

        #expect(abs(output.count - 8_000) < 80)
        // Identical L/R content: mono downmix keeps the same RMS regardless of
        // whether the converter averages or sums-with-gain.
        #expect(abs(AudioLevelMath.rms(output) - sineRMS(amplitude: 0.4)) < 0.02)
    }

    @Test func passthroughAt16kMono() throws {
        let samples = sineSamples(frequency: 100, amplitude: 0.3, sampleRate: 16_000, seconds: 0.25)
        let resampler = try StreamResampler(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
        var output = resampler.process(pcmBuffer(samples: samples, sampleRate: 16_000))
        output += resampler.flush()
        #expect(output == samples)
    }

    @Test func zeroLengthBufferYieldsNothing() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let resampler = try StreamResampler(inputFormat: format)
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)! // frameLength 0
        #expect(resampler.process(empty).isEmpty)
        #expect(resampler.flush().isEmpty)
    }
}

// MARK: - CaptureSession (tap-side logic without an engine)

@Suite struct CaptureSessionTests {
    @Test func accumulatesAndEmitsThrottledLevels() throws {
        let inputRate = 48_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var levels: [Float] = []
            func add(_ level: Float) {
                lock.lock(); levels.append(level); lock.unlock()
            }
        }
        let counter = Counter()
        let session = try CaptureSession(inputFormat: format) { counter.add($0) }

        // 1 s of audio in 1024-frame chunks arriving with no wall-clock gap:
        // the ~30 Hz throttle must collapse ~47 chunk callbacks to at most a couple.
        let samples = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: inputRate, seconds: 1)
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let chunk = Array(samples[start..<min(start + 1024, samples.count)])
            session.ingest(pcmBuffer(samples: chunk, sampleRate: inputRate))
        }
        let audio = session.finish()

        #expect(abs(audio.duration - 1.0) < 0.02)
        #expect(abs(audio.rmsLevel - sineRMS(amplitude: 0.5)) < 0.02)
        counter.lock.lock()
        let emitted = counter.levels
        counter.lock.unlock()
        #expect(emitted.count >= 1 && emitted.count <= 3)
        #expect(emitted.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func finishIsIdempotentAndIgnoresLateBuffers() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let session = try CaptureSession(inputFormat: format) { _ in }
        session.ingest(pcmBuffer(samples: [Float](repeating: 0.1, count: 160), sampleRate: 16_000))
        let first = session.finish()
        // A tap callback racing past stop() must not corrupt the result.
        session.ingest(pcmBuffer(samples: [Float](repeating: 0.9, count: 160), sampleRate: 16_000))
        let second = session.finish()
        #expect(first.samples.count == 160)
        #expect(second.samples.count == first.samples.count)
        #expect(second.peakLevel == first.peakLevel)
    }

    @Test func switchInputFormatContinuesCapture() throws {
        let session = try CaptureSession(
            inputFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        ) { _ in }
        let first = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: 48_000, seconds: 0.5)
        session.ingest(pcmBuffer(samples: first, sampleRate: 48_000))

        // Device switch: new hardware format mid-capture.
        session.switchInputFormat(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!)
        let second = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: 44_100, seconds: 0.5)
        session.ingest(pcmBuffer(samples: second, sampleRate: 44_100, channels: 2))

        let audio = session.finish()
        #expect(abs(audio.duration - 1.0) < 0.05)
        #expect(abs(audio.rmsLevel - sineRMS(amplitude: 0.5)) < 0.03)
    }

    @Test func emptySessionFinishesAsZeroLengthSilence() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let session = try CaptureSession(inputFormat: format) { _ in }
        let audio = session.finish()
        #expect(audio.samples.isEmpty)
        #expect(audio.isLikelySilence)
    }
}

// MARK: - Fixture loading

@Suite struct AudioFixtureLoaderTests {
    @Test func loadsSpokenFixture() throws {
        let audio = try AudioFixtureLoader.load(url: fixture("simple.wav"))
        // "Hello world, this is a test..." — a few seconds of clear speech.
        #expect(audio.duration > 1.0 && audio.duration < 10.0)
        #expect(audio.peakLevel > SignalGuard.peakThreshold)
        #expect(audio.rmsLevel > SignalGuard.rmsThreshold)
        #expect(!audio.isLikelySilence)
    }

    @Test func loadsSilenceFixture() throws {
        let audio = try AudioFixtureLoader.load(url: fixture("silence.wav"))
        #expect(abs(audio.duration - 3.0) < 0.1)
        #expect(audio.peakLevel < 0.005)
        #expect(audio.rmsLevel < 0.002)
        #expect(audio.isLikelySilence)
    }

    @Test func resamplesNon16kFileThroughSameConverterPath() throws {
        // Write a 44.1 kHz stereo file and load it — the loader must hit the
        // same conversion path a live 44.1 kHz mic does.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-capture-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 44_100.0
        let samples = sineSamples(frequency: 440, amplitude: 0.5, sampleRate: rate, seconds: 1)
        // Scope the writer so it deinits (and flushes the header) before reading.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                ])
            try file.write(from: pcmBuffer(samples: samples, sampleRate: rate, channels: 2))
        }

        let audio = try AudioFixtureLoader.load(url: url)
        #expect(abs(audio.duration - 1.0) < 0.02)
        #expect(abs(audio.rmsLevel - sineRMS(amplitude: 0.5)) < 0.02)
        #expect(!audio.isLikelySilence)
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try AudioFixtureLoader.load(url: fixturesDir.appendingPathComponent("does-not-exist.wav"))
        }
    }
}
