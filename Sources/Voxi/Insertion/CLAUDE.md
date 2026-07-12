# Insertion — Module Steering

**Put refined text at the cursor of whatever app is frontmost — reliably, or not at all.** Inherits the root invariants; AX/pasteboard platform detail in `steering/MACOS_PLATFORM.md`.

## Purpose & boundary

Three tiers, orchestrated by `TextInserter`: AX direct write (`AXDirectInserter`) → pasteboard + synthetic ⌘V (`PasteboardInserter`, the workhorse) → AppleScript keystroke (`AppleScriptPaster`, **opt-in setting, never auto-fallback**). `AXFocus` reads the focused element and detects secure/Electron contexts; `SmartFormatter` decides casing/spacing from the character before the caret. Consumers call `TextInserter` and get an `InsertionOutcome`.

## Public surface

- `TextInserter` — `@MainActor`; the only entry point.
- `InsertionMethod`, `InsertionOutcome`, `InsertionError`, `InsertionSettings` — `InsertionContract.swift`.
- `SmartFormatter` — pure, unit-tested.

## Status & rules

- **Probe BEFORE inserting** (`AXUIElementIsAttributeSettable`) — a tier-2 failure is undetectable after the fact; tier order and the probe are load-bearing.
- **Verify AX writes by caret advance, measured in UTF-16** (`(text as NSString).length`) — Chromium returns AX `.success` without inserting.
- **Refuse secure fields**: `IsSecureEventInputEnabled()` or `AXSecureTextField` subrole → no insertion, ever.
- Pasteboard restore only if `changeCount` is unchanged after ≥300 ms, and only when the user toggle allows (macOS 15.4+ shows pasteboard-read alerts).
- Electron apps skip tier 1 (denylist heuristic + best-effort `AXManualAccessibility`).

## Gotchas

- Synthetic ⌘V uses `CGEventSource(stateID: .privateState)` with explicit `.maskCommand`, 10 ms between events — changing timings breaks slow apps first; test in Slack/Electron.
- AppleScript uses `key code 9 using command down`, not `keystroke "v"` (⌘-QWERTY layouts); compiled `NSAppleScript` is main-thread-only and needs the Automation permission (`NSAppleEventsUsageDescription`).
- `AXUIElementSetMessagingTimeout(el, 0.3)` guards against hung apps — don't remove it.
- Headless tests can't drive real insertion; `SmartFormatter` and tier-selection logic are unit-tested, the rest is listed manual verification (dictate into TextEdit, a browser, an Electron app, a password field).
