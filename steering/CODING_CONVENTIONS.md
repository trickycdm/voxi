# Coding Conventions

> _Cross-cutting standard — the style and structure rules for all Swift code in Voxi. Concurrency, platform, persistence, and testing rules live in their own steering docs; this covers everything else._

## Structure

- **Module-per-concern under `Sources/Voxi/`,** connected by small protocols. A file lives in the module that owns its concern; cross-module types live in a `*Contract.swift` file in the owning module (`AudioCaptureContract.swift`, `HotkeyContract.swift`, `InsertionContract.swift`).
- **The extension-point rule: adding a speech engine, refiner backend, or card executor = one new file + one registry line, nothing else.** `ASREngine` → `ASREngineRegistry.makeDefaultEngines()`; `Refiner` → `RefinerChain`; `Dispatcher` → `DispatcherRegistry.v1()`. If an addition needs edits beyond that, the abstraction is being broken — stop and fix the seam instead.
- **Composition root is `AppState`** — it constructs and wires everything long-lived. Components receive collaborators explicitly (init parameters or closure hooks like `onStateChange`/`onCardQueued`); no singletons, no service locators. Shell hooks are optional closures so components stay headlessly testable.
- **Fallback chains never break the primary flow.** The refiner tries the configured LLM and falls back to rules on *any* error (`RefinerChain`); insertion degrades tier 1 → 2 → 3. New integrations follow the same shape: the user's dictation must land even when the fancy path fails.

## Errors

- **Each module has one domain error enum: `enum XError: Error, LocalizedError`** with an `errorDescription` switch (`AudioCaptureError`, `RefinerError`, `DispatcherError`, `InsertionError`, `QueueError`). Throw domain errors at module boundaries; don't leak underlying framework errors upward — wrap them with context (`engineStartFailed(String)`).
- **Fail loud internally, degrade gracefully at the user edge.** Corrupt data throws (`PersistenceError.corruptRow`); user-facing flows catch at the coordinator and surface a pill notice, never a silent no-op.

## Logging

- **One global logger: `voxiLog`** (`os.Logger`, subsystem `com.colin.voxi`, defined in `AppState.swift`). No per-module loggers, no `print` outside `CLIMode` (whose stdout *is* its interface).
- **Every dynamic value carries an explicit `privacy:` annotation.** Non-sensitive operational values are `.public` so Console shows them. **Never log transcript content, prompts, or API keys at any privacy level** — this is a dictation app; the transcript is the user's private speech.
- Levels: `.info` for lifecycle, `.warning` for degraded-but-continuing, `.error` for failed operations, `.fault` for invariant violations.

## Style

- **Every type carries a doc comment stating its purpose and, where relevant, its threading contract** (see `AudioCapture`, `CaptureSession`). Comments state constraints the code can't show — not narration of the next line.
- **UserDefaults keys are dotted and namespaced** (`audio.inputDeviceUID`, `voxi.recentDirs`), declared as statics next to their owner.
- **SwiftUI accessibility:** custom controls (Canvas-drawn meters, chord recorders) get `accessibilityLabel`/`accessibilityValue` — the pattern is already in `OnboardingView`'s level meter; keep it up for new custom controls.

## Dependencies

- **Three pinned packages: WhisperKit (argmax-oss), FluidAudio, GRDB** — pinned in `project.yml`. Adding a dependency requires justification against "one file + a registry line" (KeyboardShortcuts was dropped for exactly this reason: replaced by ~2 files of chord logic we fully control).
- **Reuse before writing.** Check the module's pure helpers (`QueueLogic`, `HubFormatting`, `AudioLevelMath`, `RefinementRules`) before adding a function that formats, validates, or decides.

## Verification

1. Build + full test suite (see `steering/TESTING_AND_VERIFICATION.md` for the complete gate).
2. New public type without a purpose comment, new `print`, or a log line with un-annotated interpolation → fix before review.
3. Adding an engine/refiner/dispatcher? Confirm the diff is one file + one registry line (+ tests).
