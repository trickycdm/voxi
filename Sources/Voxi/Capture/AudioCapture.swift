import AVFAudio
import AudioToolbox
import Foundation

enum AudioCaptureError: Error, LocalizedError {
    case alreadyCapturing
    case noInputAvailable
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing: "A capture is already in progress"
        case .noInputAvailable: "No audio input device is available"
        case .engineStartFailed(let why): "Could not start audio capture: \(why)"
        }
    }
}

/// Microphone capture. Owns an AVAudioEngine whose input tap converts to
/// 16 kHz mono Float32 as buffers arrive (CaptureSession + StreamResampler)
/// and emits ~30 Hz normalized level updates for the pill waveform.
///
/// Threading: this class is MainActor-bound (and therefore Sendable); the
/// realtime tap thread only touches the lock-protected CaptureSession.
///
/// Requires microphone permission — the first `start()` triggers the system
/// prompt via NSMicrophoneUsageDescription. Cannot be unit-tested headlessly;
/// see manual verification notes.
@MainActor
final class AudioCapture {
    /// ~30 Hz normalized RMS level (0...1) while capturing; drives the waveform UI.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var session: CaptureSession?
    private var configChangeObserver: (any NSObjectProtocol)?

    var isCapturing: Bool { session != nil }

    /// All input devices, with the system default flagged.
    nonisolated static func listInputDevices() -> [AudioInputDevice] {
        AudioDeviceCatalog.listInputDevices()
    }

    /// Begin capturing. `deviceUID` selects a specific input device; nil (or
    /// a UID that is no longer attached — e.g. an unplugged mic in settings)
    /// follows the system default.
    func start(deviceUID: String?) throws {
        guard session == nil else { throw AudioCaptureError.alreadyCapturing }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID {
            if let deviceID = AudioDeviceCatalog.deviceID(forUID: uid) {
                setInputDevice(deviceID, on: input)
            } else {
                voxiLog.warning("capture: input device \(uid, privacy: .public) not found; using system default")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }

        let session: CaptureSession
        do {
            session = try CaptureSession(inputFormat: format) { [weak self] level in
                Task { @MainActor [weak self] in self?.onLevel?(level) }
            }
        } catch {
            throw AudioCaptureError.noInputAvailable
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            session.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        self.engine = engine
        self.session = session
        observeConfigChanges(of: engine)
        voxiLog.info("capture: started (\(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch)")
    }

    /// Stop capturing and return everything recorded so far. Safe to call
    /// even if the device disappeared mid-capture. Returns an empty capture
    /// if nothing was recorded.
    func stop() async -> CapturedAudio {
        let session = session
        teardown()
        let audio = session?.finish() ?? CapturedAudio(samples: [])
        voxiLog.info("capture: stopped (\(audio.duration, format: .fixed(precision: 2), privacy: .public)s)")
        return audio
    }

    /// Discard the in-progress capture.
    func cancel() {
        let session = session
        teardown()
        _ = session?.finish()
        voxiLog.info("capture: cancelled")
    }

    // MARK: - Internals

    private func teardown() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        session = nil
    }

    /// AVAudioEngine stops itself on configuration changes (default-device
    /// switch, device unplugged, sample-rate change). Rebuild the tap with
    /// the new input format and keep going; if the input is gone, the capture
    /// stays frozen and `stop()` returns what was recorded.
    private func observeConfigChanges(of engine: AVAudioEngine) {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleConfigChange() }
        }
    }

    private func handleConfigChange() {
        guard let engine, let session else { return }
        voxiLog.info("capture: engine configuration changed; rebuilding tap")
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            voxiLog.warning("capture: input device lost; capture will finish with audio so far")
            return
        }
        session.switchInputFormat(format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            session.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            voxiLog.warning("capture: engine restart failed (\(error.localizedDescription, privacy: .public)); capture will finish with audio so far")
        }
    }

    /// Pin the engine's AUHAL input unit to a specific CoreAudio device.
    /// When never called, the engine follows the system default input.
    private func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let audioUnit = input.audioUnit else {
            voxiLog.warning("capture: input node has no audio unit; using system default device")
            return
        }
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            voxiLog.warning("capture: failed to select input device (OSStatus \(status, privacy: .public)); using system default")
        }
    }
}
