import AVFAudio

enum AudioResampleError: Error, LocalizedError {
    case unsupportedInputFormat(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat(let desc): "Cannot convert audio format: \(desc)"
        }
    }
}

/// Incrementally converts PCM buffers in any format to Voxi's ASR contract
/// format (16 kHz mono Float32) as they arrive, so a capture never needs a
/// whole-file resample at the end.
///
/// Not thread-safe: callers serialize access (CaptureSession does so under
/// its lock; the fixture loader is single-threaded).
final class StreamResampler {
    static let outputSampleRate: Double = 16_000

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// nil when the input already matches the output format (passthrough).
    private let converter: AVAudioConverter?
    private let ratio: Double

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioResampleError.unsupportedInputFormat(inputFormat.description)
        }
        ratio = Self.outputSampleRate / inputFormat.sampleRate
        let isPassthrough = inputFormat.commonFormat == .pcmFormatFloat32
            && inputFormat.sampleRate == Self.outputSampleRate
            && inputFormat.channelCount == 1
        if isPassthrough {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
                throw AudioResampleError.unsupportedInputFormat(inputFormat.description)
            }
            self.converter = converter
        }
    }

    /// Convert one incoming buffer, returning whatever output frames the
    /// converter can produce now (rate conversion buffers a small tail
    /// internally — collect it with `flush()` at end of capture).
    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else {
            return Self.floats(from: buffer)
        }

        var output: [Float] = []
        let feed = SingleBufferFeed(buffer)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
                break
            }
            let status = converter.convert(to: out, error: nil) { _, inputStatus in
                guard let next = feed.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }
            output.append(contentsOf: Self.floats(from: out))
            // Loop only if the output buffer filled completely — there may be
            // more converted frames pending for this input.
            guard status == .haveData, out.frameLength == capacity else { break }
        }
        return output
    }

    /// Drain the converter's internal tail at end of stream. The resampler
    /// cannot be used after flushing.
    func flush() -> [Float] {
        guard let converter else { return [] }
        var output: [Float] = []
        for _ in 0..<64 { // safety bound; tail is at most a few frames
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 1024) else {
                break
            }
            let status = converter.convert(to: out, error: nil) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            output.append(contentsOf: Self.floats(from: out))
            guard status == .haveData, out.frameLength > 0 else { break }
        }
        return output
    }

    /// Hands one buffer to AVAudioConverter's input block exactly once. The
    /// block is annotated @Sendable in the Swift overlay, but the converter
    /// invokes it synchronously on the calling thread during `convert`, so
    /// this single-threaded handoff is safe.
    private final class SingleBufferFeed: @unchecked Sendable {
        private var pending: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { pending = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { pending = nil }
            return pending
        }
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
