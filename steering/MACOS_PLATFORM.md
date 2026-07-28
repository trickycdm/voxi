# macOS Platform Rules

> _Cross-cutting standard — the platform contracts (TCC, event taps, windows, realtime audio, subprocesses) that Voxi depends on. These were established by local verification during M0 research (`docs/architecture.md` Decision Log); breaking one usually fails silently on some other machine or after the next rebuild, not in front of you._

## Windows & panels

- **One instance per app lifetime, shown and hidden — never `close()`d.** The pill panel, hub, and per-card log windows follow this: create lazily, set `isReleasedWhenClosed = false` explicitly, then `orderOut`/`orderFront` for the rest of the app's life. AppKit's default (`isReleasedWhenClosed = true` for programmatic windows) frees the window out from under you on close. Exemplars: `PillPanel` via `PillController`, `HubWindowController.makeWindow`.
- **Non-activating panels use `orderFrontRegardless()`;** real windows use `makeKeyAndOrderFront(nil)` + `NSApp.activate(ignoringOtherApps: true)`. The pill must never steal focus from the app being dictated into — that's why it's an `NSPanel` with `.nonactivatingPanel`.
- **All app windows are controller-owned plain `NSWindow`s** (Hub via `HubWindowController`, logs via `LogWindowController`, onboarding via `AppDelegate` — see the comment at `VoxiApp.showOnboarding()`). No SwiftUI `Window` scene remains (the only scene is the `MenuBarExtra`): AppState must open windows and deep-link sections programmatically (menu bar, notification taps), and `@Environment(\.openWindow)` only exists inside a scene's environment — it is unavailable everywhere in this app, including all `NSHostingView`-hosted trees.
- **Long-lived AppKit machinery (event tap, pill panel, DB) is owned by `AppDelegate`/`AppState`, never by a SwiftUI scene** — scenes are torn down and rebuilt at SwiftUI's discretion.
- **Never reach the delegate via `NSApp.delegate as? AppDelegate` from a view.** Under `@NSApplicationDelegateAdaptor`, SwiftUI installs its own wrapper as `NSApp.delegate` and only forwards protocol calls — the cast fails and the optional chain silently no-ops. This shipped twice: a dead "Run Onboarding Again" menu item (fixed 0.4.1) and a Check-for-Updates control that never rendered from 0.3.x to 0.4.2. `VoxiApp` holds the real delegate; hand views what they need — a closure (`MenuBarContent.showOnboarding`) or `.environment(appDelegate.updater)` read via `@Environment(UpdaterController.self)`.
- **User feedback belongs on surfaces Voxi owns, not on system-framework alerts.** The app is an `LSUIElement` accessory agent, so panels another framework fronts (Sparkle's "You're up to date" alert) can open behind everything and read as "the button did nothing" — even after `NSApp.activate(ignoringOtherApps:)`. Mirror the outcome into inline UI in an owned window and let the framework's windows be a bonus, not the only signal. Exemplar: `UpdaterController.status` rendered in `HubRailView`'s footer.
- **`NSHostingView.sizingOptions = [.preferredContentSize]` resizes the window around a fixed bottom-left origin.** A borderless panel whose SwiftUI content changes width therefore drifts sideways (this shipped as the off-centre pill). If position matters, observe `NSView.frameDidChangeNotification` on the hosting view and re-pin the origin — with an equal-frame early-return, because your own `setFrame` re-fires the notification. Don't override `setFrame`; NSHostingView calls it internally at undocumented times. Exemplar: `PillPanel.recenterAfterContentResize()`.

## Event tap (global hotkeys)

- **Exactly one `CGEventTap` serves all chords** (`ModifierChordTap`). Do not add a second tap; add chord logic to the pure `ChordStateMachine` instead.
- **Re-enable the tap on `.tapDisabledByTimeout` / `.tapDisabledByUserInput`** — without this every hotkey dies silently and permanently. The handling lives in the tap callback; never remove it.
- **The tap callback sits on every keystroke system-wide: it must stay allocation-free and fast.** Extract scalars, feed the state machine, return.
- **Returning nil from the callback swallows the event for every app.** Only done for Esc / fn+Space during an active dictation session. Adding a new swallow needs explicit justification.
- **Physical fn key = `flagsChanged && keyCode == 63`.** The Globe system action (`AppleFnUsageType`) fires independently and cannot be swallowed — onboarding warns the user to set it to "Do Nothing"; don't try to suppress it in code.
- **Accessibility permission only** — the tap configuration deliberately avoids needing Input Monitoring. `CGEvent.tapCreate` returns nil when untrusted; `HotkeyController` polls `AXIsProcessTrusted()` (there is no grant notification) and rebuilds the tap on the flip.

## TCC / permissions

- **TCC grants key off the signing identity + bundle id.** Signing is per-config in `project.yml` (both team `F7H963S3B4`, **never** ad-hoc `-`): Debug = "Apple Development" — daily grants key off this identity and survive rebuilds; Release = "Developer ID Application" + hardened runtime for distribution (`Scripts/release.sh`). Never change the Debug identity or `com.colin.voxi` casually.
- **The two identities share one bundle id**, so running a Release build on the dev machine presents a different identity to TCC — expect Accessibility/Microphone/Automation re-prompts, and switching between Debug and Release builds can flap grants.
- Grants gone stale anyway? `tccutil reset Accessibility com.colin.voxi` (same for `Microphone`, `AppleEvents`), then re-grant via onboarding's live re-checks.
- **Automation (Apple Events) grants are per target app**: System Events (AppleScript insertion tier) and iTerm2/Terminal (the iTerm hand-off dispatcher + resume button, `TerminalLauncher`) each prompt separately on first use. Denial surfaces as AppleScript error **-1743** — both call sites map it to a message naming the target app and the Settings pane.
- **`kAXTrustedCheckOptionPrompt` is a mutable ObjC global and not concurrency-safe** — the hardcoded literal string is used instead (`HotkeyController`). Leave it that way.

## Distribution / notarisation

The release pipeline is `Scripts/release.sh X.Y.Z`; the runbook is `docs/RELEASING.md`. The load-bearing gotchas, learned the hard way and encoded in the script:

- **Sign the DMG itself, don't just notarise it.** `hdiutil create` emits an *unsigned* image; Gatekeeper's `spctl -a -t open --context context:primary-signature` rejects an unsigned DMG even after a successful notarisation. `codesign --sign "Developer ID Application: …"` the `.dmg` before submitting it.
- **Notarise + staple twice — the app, then the DMG.** Staple the `.app` first, build the DMG from the stapled app, then notarise + staple the DMG. A single DMG submission can only staple the DMG (read-only filesystem), leaving the app inside needing an online ticket lookup — offline first-launch then fails.
- **`grep -q` on a pipe dies under `set -o pipefail`.** `codesign -dvv "$APP" | grep -q …` SIGPIPEs the producer when grep exits early, so the pipeline returns non-zero even on a match and false-fails the gate. Capture to a variable first (`INFO="$(codesign -dvv … 2>&1)"; grep -q … <<< "$INFO"`).
- **Release is Manual signing style** (`project.yml` `configs.Release`): Developer ID with unrestricted entitlements needs no provisioning profile, and Automatic export can demand an interactive Apple ID sign-in mid-script. The `Scripts/exportOptions.plist` pins method `developer-id`, the team, and the cert.
- **Hardened runtime did not need any extra entitlements.** The existing set (non-sandboxed, apple-events, audio-input) is enough; CoreML model load, the event tap, AX insertion, and the `claude` subprocess spawn all work under it (verified via the CLI harness on the notarised binary). Add `com.apple.security.cs.*` escape hatches only if a real runtime failure appears — a minimal entitlement set is what Gatekeeper and notarisation prefer.

## Realtime audio

- **The tap thread touches only the lock-protected `CaptureSession`.** No allocation, no logging, no MainActor hops per buffer — a single smoothed `Float` level crosses to the MainActor at ~30 Hz, nothing else.
- **The tap closure must be `@Sendable`** — see `steering/CONCURRENCY.md`; this crashed the app once already.
- **`AVAudioEngine` stops itself on config changes** (device unplug/switch, sample-rate change). `AudioCapture` rebuilds the tap on `.AVAudioEngineConfigurationChange`; a lost device freezes the capture and `stop()` returns what was recorded. Preserve that degrade-gracefully behavior.
- **One consumer per `AudioCapture` instance.** `onLevel` is a single closure slot; a second consumer must create its own instance (each owns its own engine), not steal the slot.

## Subprocesses (claude / any future dispatcher)

All established in `ClaudeCodeDispatcher.swift` — copy its shape:

- **Spawn directly with an argument array** (`Process.arguments`) — never through a shell; no quoting/injection surface. (This rule is about `Process`. `TerminalLauncher` handing a command line to iTerm/Terminal is the deliberate exception — a terminal's shell parsing input is the product; everything variable is `shellQuoted` and the prompt travels by temp file, never on the command line.)
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
