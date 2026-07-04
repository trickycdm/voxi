import AVFAudio
import Foundation

/// Loads an audio file (any sample rate/channel count AVAudioFile can read)
/// into `CapturedAudio` through the same StreamResampler path as live
/// capture. Used by tests and the CLI harness to exercise the transcription
/// pipeline without a microphone.
enum AudioFixtureLoader {
    static func load(url: URL) throws -> CapturedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let resampler = try StreamResampler(inputFormat: format)

        var samples: [Float] = []
        let chunkFrames: AVAudioFrameCount = 8192
        // Note: reading at EOF throws (a nil ObjC error) rather than returning
        // zero frames, so the loop is bounded by framePosition instead.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw AudioResampleError.unsupportedInputFormat(format.description)
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: resampler.process(buffer))
        }
        samples.append(contentsOf: resampler.flush())
        return CapturedAudio(samples: samples)
    }
}
