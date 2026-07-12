# Concurrency

> _Cross-cutting standard — applies to every module. Voxi builds with Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete` in `project.yml`); every rule here exists because the compiler alone did not prevent a real bug, or prevents one only if you follow the pattern. Each rule cites its in-repo exemplar — read the exemplar before inventing a new shape._

Isolation bugs in this app are not theoretical: an actor-isolation trap on the realtime audio thread crashed the app in production use. The compiler catches data races at build time; these rules cover the holes — un-annotated ObjC SDK callbacks, C callbacks, realtime threads, and subprocess plumbing.

## The rules

- **UI-facing stateful controllers are `@MainActor @Observable` classes.** `AppState`, `PillController`, `QueueRunner`, `HotkeyController`, `DictationCoordinator`, `AudioCapture` all follow this. State the isolation in the type declaration, not per-member. Mark non-observed dependencies `@ObservationIgnored` (see `QueueRunner`).

- **Closures handed to ObjC/AVFoundation APIs MUST be marked `@Sendable` when the framework invokes them off-main.** A plain closure literal formed inside a `@MainActor` type inherits MainActor isolation; the SDK's block types are mostly *not* annotated `@Sendable`, so the compiler accepts the closure silently — and compiles a runtime executor check into it that **traps** when the framework calls it on its own queue. This crashed Voxi: the `AVAudioEngine` input-tap closure trapped on AVFAudio's realtime messenger queue. Exemplar: the tap closures in `AudioCapture.start(deviceUID:)` and `handleConfigChange()` (`Sources/Voxi/Capture/AudioCapture.swift`). If you pass a closure to a framework and don't know what thread calls it back, `@Sendable` is the safe default.

- **`@unchecked Sendable` + an explicit lock is reserved for boundary objects that genuinely cross threads,** and the class doc-comment must state the protected invariant. Two lock idioms exist: `NSLock` on `CaptureSession` (realtime audio boundary) and `OSAllocatedUnfairLock` on `ProcessBox`/`RunState` in `ClaudeCodeDispatcher.swift` (subprocess boundary). Prefer `OSAllocatedUnfairLock` for new code. Never reach for `@unchecked Sendable` to silence a compiler error on an ordinary type — restructure instead.

- **Extract Sendable scalars at C-callback boundaries; never move framework objects across isolation.** `CGEvent` and `AVAudioPCMBuffer` are non-Sendable. The event-tap callback reads `keyCode`/`flags`/`isRepeat` scalars out of the `CGEvent` and only those cross into isolated code (`Sources/Voxi/Hotkeys/ModifierChordTap.swift`). The audio tap hands the buffer only to the lock-protected `CaptureSession`, and only a single smoothed `Float` hops to the MainActor.

- **`MainActor.assumeIsolated { }` is allowed only in callbacks contractually delivered on the main run loop** — main-queue `NotificationCenter` observers, main-run-loop `Timer`s, the event-tap callback (taps deliver on the installing run loop). Every use carries a comment saying why the assumption holds. Exemplars: `PillController` timers, `AudioCapture.observeConfigChanges`. If you cannot state why the callback is main-thread, use `Task { @MainActor in … }` instead.

- **`nonisolated` marks the pure/thread-safe escape hatches, deliberately.** Pure statics and thread-safe reads reachable from any context are `nonisolated static` (`AudioCapture.listInputDevices()`, `HotkeyController.appleFnUsageType()`); engine identity is `nonisolated let` (`ParakeetEngine.id`). `nonisolated(unsafe)` appears exactly once — the WhisperKit pipe serialized by its owning actor (`WhisperKitEngine.swift`) — and any new use needs the same "serialized by X" justification comment.

- **Continuations resume exactly once, enforced by a lock, not by control-flow reasoning.** Subprocess completion in `ClaudeCodeDispatcher` funnels through a `resumeGuard` lock and fires only after stdout EOF **and** stderr EOF **and** process exit. Copy that shape (`maybeFinish`) for any new callback-to-async bridge with multiple completion sources.

- **Values crossing actor or process boundaries are Sendable value types.** DB records (`HistoryEntry`, `ActionCard`), dispatch events, and capture results are `Sendable` structs/enums. If a type needs to cross a boundary and can't be a value type, it needs an isolation story (actor, `@MainActor`, or locked `@unchecked Sendable`) — pick one explicitly.

## Verification

Before completing any change that adds a closure passed to a framework, a new lock, or a new `nonisolated`/`assumeIsolated`/`@unchecked Sendable`:

1. Build with the standard command — strict concurrency is the gate; zero warnings tolerated in touched files.
2. For framework callbacks: state (in a comment or the PR) which thread/queue invokes the closure, and why its annotation matches.
3. For anything touching the audio tap path: run a live dictation (`fn` hold) — the trap only fires at runtime, on the realtime queue, never in tests.
4. `xcodebuild … test` — the 379-test suite runs in-process on the app binary and exercises the pure logic around these boundaries.
