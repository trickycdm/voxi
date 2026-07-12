# macOS Platform Rules

> _Cross-cutting standard — the platform contracts (TCC, event taps, windows, realtime audio, subprocesses) that Voxi depends on. These were established by local verification during M0 research (`docs/architecture.md` Decision Log); breaking one usually fails silently on some other machine or after the next rebuild, not in front of you._

## Windows & panels

- **One instance per app lifetime, shown and hidden — never `close()`d.** The pill panel, queue window, and hub follow this: create lazily, set `isReleasedWhenClosed = false` explicitly, then `orderOut`/`orderFront` for the rest of the app's life. AppKit's default (`isReleasedWhenClosed = true` for programmatic windows) frees the window out from under you on close. Exemplars: `PillPanel` via `PillController`, `QueueWindowController.makeWindow`.
- **Non-activating panels use `orderFrontRegardless()`;** real windows use `makeKeyAndOrderFront(nil)` + `NSApp.activate(ignoringOtherApps: true)`. The pill must never steal focus from the app being dictated into — that's why it's an `NSPanel` with `.nonactivatingPanel`.
- **Windows that must exist before any SwiftUI scene does are plain `NSWindow`s owned by `AppDelegate`** (onboarding — see the comment at `VoxiApp.showOnboarding()`). Everything else can be a SwiftUI `Window` scene, but note `@Environment(\.openWindow)` is unavailable inside `NSHostingView`-hosted trees like the queue window.
- **Long-lived AppKit machinery (event tap, pill panel, DB) is owned by `AppDelegate`/`AppState`, never by a SwiftUI scene** — scenes are torn down and rebuilt at SwiftUI's discretion.
- **`NSHostingView.sizingOptions = [.preferredContentSize]` resizes the window around a fixed bottom-left origin.** A borderless panel whose SwiftUI content changes width therefore drifts sideways (this shipped as the off-centre pill). If position matters, observe `NSView.frameDidChangeNotification` on the hosting view and re-pin the origin — with an equal-frame early-return, because your own `setFrame` re-fires the notification. Don't override `setFrame`; NSHostingView calls it internally at undocumented times. Exemplar: `PillPanel.recenterAfterContentResize()`.

## Event tap (global hotkeys)

- **Exactly one `CGEventTap` serves all chords** (`ModifierChordTap`). Do not add a second tap; add chord logic to the pure `ChordStateMachine` instead.
- **Re-enable the tap on `.tapDisabledByTimeout` / `.tapDisabledByUserInput`** — without this every hotkey dies silently and permanently. The handling lives in the tap callback; never remove it.
- **The tap callback sits on every keystroke system-wide: it must stay allocation-free and fast.** Extract scalars, feed the state machine, return.
- **Returning nil from the callback swallows the event for every app.** Only done for Esc / fn+Space during an active dictation session. Adding a new swallow needs explicit justification.
- **Physical fn key = `flagsChanged && keyCode == 63`.** The Globe system action (`AppleFnUsageType`) fires independently and cannot be swallowed — onboarding warns the user to set it to "Do Nothing"; don't try to suppress it in code.
- **Accessibility permission only** — the tap configuration deliberately avoids needing Input Monitoring. `CGEvent.tapCreate` returns nil when untrusted; `HotkeyController` polls `AXIsProcessTrusted()` (there is no grant notification) and rebuilds the tap on the flip.

## TCC / permissions

- **TCC grants key off the signing identity + bundle id.** The project signs with a real Apple Development identity (team `F7H963S3B4`, set in `project.yml` — **not** ad-hoc `-`) precisely so Accessibility/Microphone grants survive rebuilds. Never switch back to ad-hoc signing; never change `com.colin.voxi` casually.
- Grants gone stale anyway? `tccutil reset Accessibility com.colin.voxi` (same for `Microphone`), then re-grant via onboarding's live re-checks.
- **`kAXTrustedCheckOptionPrompt` is a mutable ObjC global and not concurrency-safe** — the hardcoded literal string is used instead (`HotkeyController`). Leave it that way.

## Realtime audio

- **The tap thread touches only the lock-protected `CaptureSession`.** No allocation, no logging, no MainActor hops per buffer — a single smoothed `Float` level crosses to the MainActor at ~30 Hz, nothing else.
- **The tap closure must be `@Sendable`** — see `steering/CONCURRENCY.md`; this crashed the app once already.
- **`AVAudioEngine` stops itself on config changes** (device unplug/switch, sample-rate change). `AudioCapture` rebuilds the tap on `.AVAudioEngineConfigurationChange`; a lost device freezes the capture and `stop()` returns what was recorded. Preserve that degrade-gracefully behavior.
- **One consumer per `AudioCapture` instance.** `onLevel` is a single closure slot; a second consumer must create its own instance (each owns its own engine), not steal the slot.

## Subprocesses (claude / any future dispatcher)

All established in `ClaudeCodeDispatcher.swift` — copy its shape:

- **Spawn directly with an argument array** (`Process.arguments`) — never through a shell; no quoting/injection surface.
- **`standardInput = FileHandle.nullDevice`** or the child may stall ~3 s probing stdin.
- **Set `PATH` explicitly** — the app's launch context (Finder/launchd) does not have the user's shell PATH.
- **Completion = stdout EOF ∧ stderr EOF ∧ process exit,** guarded to resume exactly once. Resuming on exit alone loses late-buffered output.
- **Cancel = SIGTERM, then SIGKILL after a 3 s grace.** A SIGTERM'd claude exits 143 with no result event — treat as cancelled, not failed-with-result.
- **NDJSON lines can be hundreds of KB** — no line-length assumptions in stream parsing.
- **Binary discovery probes real paths first, login-shell `which` LAST** — the login shell on this machine resolves to a stale claude; probe order is load-bearing (`ClaudeBinaryLocator`).

## Verification

1. Anything touching the tap, TCC, pill, or capture has a **manual verification step** — list it explicitly in the PR/plan and run it (live dictation, permission re-grant, device unplug). These paths cannot be exercised headlessly; saying so beats pretending tests cover them.
2. Subprocess changes: run the gated integration test — `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 xcodebuild … test -only-testing:VoxiTests/DispatchersIntegrationTests` (costs a few cents).
3. After signing/entitlement changes: rebuild, relaunch, and confirm hotkeys + mic still work without re-granting.
