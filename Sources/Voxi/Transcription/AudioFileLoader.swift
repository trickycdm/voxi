import AVFoundation
import Foundation

enum AudioFileLoaderError: Error, LocalizedError {
    case unreadable(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): "Could not read audio file: \(why)"
        case .conversionFailed(let why): "Could not convert audio: \(why)"
        }
    }
}

/// Loads an audio file into the 16 kHz mono Float32 sample contract both
/// engines share. Any format/sample-rate AVFoundation can read is accepted.
enum AudioFileLoader {
    static let targetSampleRate: Double = 16_000

    static func loadSamples16kMono(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileLoaderError.unreadable(String(describing: error))
        }
        guard file.length > 0 else { return [] }

        let inFormat = file.processingFormat
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioFileLoaderError.unreadable("could not allocate read buffer")
        }
        do {
            try file.read(into: inBuffer)
        } catch {
            throw AudioFileLoaderError.unreadable(String(describing: error))
        }

        if inFormat.sampleRate == targetSampleRate,
           inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            return samples(from: inBuffer)
        }
        return try convert(inBuffer, from: inFormat)
    }

    private static func convert(_ inBuffer: AVAudioPCMBuffer, from inFormat: AVAudioFormat) throws -> [Float] {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioFileLoaderError.conversionFailed(
                "no converter from \(inFormat.sampleRate) Hz x\(inFormat.channelCount)")
        }

        let ratio = targetSampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(inBuffer.frameLength) * ratio).rounded(.up)) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AudioFileLoaderError.conversionFailed("could not allocate output buffer")
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let conversionError {
            throw AudioFileLoaderError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw AudioFileLoaderError.conversionFailed("converter reported an error")
        }
        return samples(from: outBuffer)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
