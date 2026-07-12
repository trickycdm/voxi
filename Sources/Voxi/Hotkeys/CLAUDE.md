# Hotkeys — Module Steering

**One `CGEventTap` → a stream of chord events.** Inherits the root invariants; event-tap platform rules live in `steering/MACOS_PLATFORM.md`.

## Purpose & boundary

Detects the global modifier chords (hold-fn PTT, fn+Space toggle, fn+⌃ command, Esc cancel), persists bindings, and polls Accessibility trust. All *decision* logic is in the pure `ChordStateMachine`; `ModifierChordTap` owns the single tap; `HotkeyController` is the public face. Consumers get an `AsyncStream<HotkeyEvent>` and never see CGEvents.

## Public surface

- `HotkeyController` — `@MainActor @Observable`; `events` stream, `bindings` (persisted `ChordBinding`s), `permissionStatus`, `resetChordState()`.
- `HotkeyEvent`, `ChordBinding` — `HotkeyContract.swift`.
- `ChordStateMachine` — pure, exhaustively unit-tested; **behavior changes go here first**, with tests.

## Status & rules

- **Never add a second event tap** — extend `ChordStateMachine` instead. The callback sits on every keystroke system-wide and must stay allocation-free.
- **Never remove the `.tapDisabledByTimeout`/`.tapDisabledByUserInput` re-enable** — without it all hotkeys die silently and permanently.
- Swallowing events (returning nil) affects every app: only Esc and fn+Space during an active session are swallowed; new swallows need explicit justification.
- Permission is polled (`AXIsProcessTrusted()`, 1 s timer) because macOS provides no grant notification; the tap is built/torn on the flip.

## Gotchas

- Physical fn = `flagsChanged && keyCode == 63` **only** — `.maskSecondaryFn` also fires on arrow/F-keys.
- The Globe system action (`AppleFnUsageType`) fires independently and cannot be swallowed; onboarding tells the user to set "Press 🌐 key to: Do Nothing".
- Only Sendable scalars (`keyCode`, `flags`, `isRepeat`) leave the C callback — the `CGEvent` itself never crosses isolation.
- Accessibility only — the tap deliberately avoids Input Monitoring; `CGEvent.tapCreate` returns nil when untrusted (that's the permission signal, not an error).
- The KeyboardShortcuts package was evaluated and dropped (can't record modifier-only chords) — don't re-add it; the custom `ChordCapture` recorder in Hub covers bindings.
