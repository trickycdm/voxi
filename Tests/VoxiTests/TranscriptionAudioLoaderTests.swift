import AVFoundation
import Foundation
import Testing
@testable import Voxi

@Suite struct TranscriptionAudioLoaderTests {
    private func tempWavURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxi-audio-\(UUID().uuidString).wav")
    }

    /// Writes a sine wave WAV (16-bit PCM container) and returns its URL.
    private func writeSineWav(
        to url: URL, sampleRate: Double, channels: UInt32, seconds: Double, frequency: Double = 440
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }

    @Test func loads16kMonoWavVerbatim() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWav(to: url, sampleRate: 16_000, channels: 1, seconds: 1.0)

        let samples = try AudioFileLoader.loadSamples16kMono(from: url)
        #expect(samples.count == 16_000)
        // Sine content survives the int16 container round-trip.
        let expected = Float(sin(2 * .pi * 440 * 100.0 / 16_000)) * 0.5
        #expect(abs(samples[100] - expected) < 0.001)
    }

    @Test func resamplesStereo44kToMono16k() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWav(to: url, sampleRate: 44_100, channels: 2, seconds: 2.0)

        let samples = try AudioFileLoader.loadSamples16kMono(from: url)
        // 2 s of audio at 16 kHz, allowing for resampler edge effects.
        #expect(abs(samples.count - 32_000) < 320)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.2 && peak <= 1.0)
    }

    @Test func missingFileThrowsUnreadable() {
        let url = tempWavURL()
        #expect(throws: AudioFileLoaderError.self) {
            _ = try AudioFileLoader.loadSamples16kMono(from: url)
        }
    }

    @Test func silenceStaysSilent() throws {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSineWav(to: url, sampleRate: 16_000, channels: 1, seconds: 0.5, frequency: 0)

        let samples = try AudioFileLoader.loadSamples16kMono(from: url)
        #expect(samples.count == 8_000)
        #expect((samples.map(abs).max() ?? 1) < 0.0001)
    }
}
