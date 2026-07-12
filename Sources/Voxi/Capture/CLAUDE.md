# Capture — Module Steering

**Microphone → 16 kHz mono Float32 samples + ~30 Hz normalized levels.** Inherits the repo invariants in the root `CLAUDE.md`; realtime and concurrency rules in `steering/MACOS_PLATFORM.md` / `steering/CONCURRENCY.md` apply with full force here.

## Purpose & boundary

Owns the `AVAudioEngine` input tap and everything between the hardware and a clean `CapturedAudio` buffer: device selection (`AudioDeviceCatalog`), incremental resampling (`StreamResampler`), sample accumulation (`CaptureSession`), level math (`AudioLevelMath`), and the silence/hallucination gate (`SignalGuard` in `AudioCaptureContract.swift`). Consumers see only `CapturedAudio`, the `onLevel` callback, and `AudioInputDevice` — never the engine, tap, or session.

## Public surface

- `AudioCapture` — `@MainActor`; `start(deviceUID:)` / `stop() → CapturedAudio` / `cancel()`; `onLevel: ((Float) -> Void)?`; `listInputDevices()`.
- `CapturedAudio`, `AudioInputDevice`, `SignalGuard` — value types in `AudioCaptureContract.swift`.
- `AudioLevelMath` — pure RMS → dB → normalized 0…1 mapping (floor −50 dBFS, ceiling −6).

## Status & rules

- **One consumer per `AudioCapture` instance.** `onLevel` is a single closure slot and the engine is exclusive. A second consumer (e.g. the onboarding mic test) creates its own instance — instances coexist fine; sharing one does not.
- The realtime tap touches **only** the lock-protected `CaptureSession`; a single smoothed `Float` hops to the MainActor per level tick. No allocation, logging, or other MainActor work on the tap thread.
- Engine config changes (device unplug/switch) self-stop the engine; `AudioCapture` rebuilds the tap and degrades gracefully — a lost device freezes the capture and `stop()` returns what was recorded. Preserve this.

## Gotchas

- **The tap closure MUST be `@Sendable`** (`AudioCapture.start` and `handleConfigChange`). Without it the closure inherits `@MainActor` from the class and **traps at runtime** on AVFAudio's realtime messenger queue — this crashed the app on its first real capture (2026-07-11). The compiler will not warn you.
- `AVAudioPCMBuffer` is non-Sendable — it never crosses isolation; only the session ingests it.
- This module **cannot be unit-tested headlessly** (needs mic + TCC). Pure parts (`AudioLevelMath`, `StreamResampler`, `SignalGuard`) are tested; `AudioCapture` itself gets listed manual verification (live dictation, device unplug mid-capture).
- Levels are display-calibrated: the onboarding mic-test pass gate (`MicTestGate`) is tuned against `SignalGuard.peakThreshold` on **raw** levels — don't insert gain ahead of it.
