# CommandQueue — Module Steering

**The action-card lifecycle: draft → review → explicit dispatch → live logs → terminal state.** Inherits the root invariants; persistence rules in `steering/PERSISTENCE.md`.

## Purpose & boundary

`ActionCard` + `CardStatus` model the card; `QueueRunner` executes exactly one dispatch per card via a `Dispatcher` and owns live-run state; `QueueModel` is the observable card list (GRDB `ValueObservation`); `QueuePaneView` (master–detail split hosted as the Hub's Queue section) + `CardDetailView` are the UI. Pure decisions live in `QueueSupport.swift` (`QueueLogic`, `QueueParams`). The DB is reached only through `CardStore` (Persistence).

## Public surface

- `QueueRunner` — `@MainActor @Observable`; `dispatch(cardID:)`, `cancel(cardID:)`, `awaitCompletion(cardID:)`, `liveRuns`.
- `QueueModel` — observable cards + edits.
- `QueueLogic` / `QueueParams` — pure; dispatchability, params encode/decode.
- `CardStatus.canTransition(to:)` — the lifecycle contract.

## Status & rules

- **All status writes go through validated `CardStore` helpers** (which enforce `canTransition`) — never write the status column directly. `beginDispatch` is the queued→dispatched entry: it records the dispatcher choice atomically with the transition (and is the only post-creation `dispatcherID` write).
- **Nothing auto-dispatches.** Cards run only from the explicit Dispatch action. Product safety rule; do not add auto-run paths.
- **Log display precedence:** while `dispatched`/`running`, show the in-memory `LiveRun` tail (32 KB cap); otherwise the persisted `log` column. Keep both sides consistent when adding views.
- Log persistence is throttled (`LogThrottler`, ~250 ms) with an atomic `log = log || ?` append — don't write logs any other way.
- Interrupted-at-crash cards are reconciled to `failed` on launch (`CardStore.reconcileInterrupted`, called from `AppState.start`).
- `QueueRunner` is UI-agnostic: shell integration is optional closures; tests inject fake dispatchers/resolvers and never touch AppKit.

## Gotchas

- Cards are editable **only** while `.queued` — prompt/params lock at dispatch.
- **The dispatcher is chosen at dispatch time by the button pressed** ("Open in iTerm" / "Run Headless" → `QueueRunner.dispatch(cardID:as:)`), recorded atomically with queued→dispatched via `CardStore.beginDispatch`. There is no stored-dispatcher picker; the card face renders the **spec union** across all registered dispatchers (`QueueLogic.combinedSpecs`), split by `DispatcherParamSpec.placement` (face / Advanced disclosure / hidden). `resumeSessionID` never renders as a field — it's the resume-session chip on follow-up cards. Unknown dispatcher ids fail at dispatch via `failBeforeRun`, never at edit; "Run All" drains on stored ids.
- The "Open in iTerm" button on terminal cards with a `sessionID` is a fire-and-forget view action calling `TerminalLauncher` directly — not a card lifecycle transition; the queue's record of the run is untouched.
- Retry re-queues the same prompt and clears prior run bookkeeping; it is a fresh run, not a resume.
- Different cards run concurrently by design; only same-card double-dispatch is guarded.
- The queue is a pane of the Hub (`QueuePaneView` inside `HubView`), not its own window; the Hub itself is one reusable controller-owned NSWindow per app lifetime (`HubWindowController`) — shown/hidden, never recreated. Deep links (menu bar ⌘J, notification taps) go through `AppState.openHub(section:revealCard:)`. `@Environment(\.openWindow)` is unavailable app-wide (no SwiftUI `Window` scene exists).
- Dictating a command never opens a window — the card lands with a pill notice + system notification (tap deep-links to the card). Do not reintroduce auto-open; it steals focus mid-work.
- `CardDetailView` is hosted with `.id(card.id)` in the detail column — its prompt/params drafts seed in `.onAppear`, so losing the identity reset makes edits bleed across selections.
- `paramsJSON` is a dispatcher-defined `[String: String]` blob — the queue treats it as opaque; interpret keys only in the owning dispatcher.
- Chip styling is token-driven (`CardStatus.chipBackground/.chipForeground`, unit-tested) per `steering/DESIGN_SYSTEM.md` — don't reintroduce named SwiftUI colors.
