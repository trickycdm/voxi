# Dispatchers — Module Steering

**Pluggable executors for action cards: interactive iTerm hand-off (default) and headless Claude Code.** Inherits the root invariants; subprocess platform rules in `steering/MACOS_PLATFORM.md`, Sendable patterns in `steering/CONCURRENCY.md`.

## Purpose & boundary

`Dispatcher` (protocol) + `DispatcherRegistry` are the extension seam — a new executor is one file + one registry line; registration order is the UI picker order and `DispatcherRegistry.defaultDispatcherID` is what new cards get. `ClaudeCodeITermDispatcher` (default) opens a new iTerm window (Terminal.app fallback) running interactive `claude` via `TerminalLauncher` and succeeds immediately — a hand-off, not a tracked run. `ClaudeCodeDispatcher` spawns `claude -p … --output-format stream-json`, parses NDJSON via `StreamJSONParser`, and streams `DispatchEvent`s upward. `ClaudeBinaryLocator` finds and version-gates the binary; `RecentDirectories` is the working-dir MRU. **`QueueRunner` (CommandQueue) is the only caller of `execute`** (`CardDetailView`'s resume button calls `TerminalLauncher` directly) — dispatchers never touch the DB or UI.

## Public surface

- `Dispatcher`, `DispatchEvent`, `DispatchResult`, `DispatcherParamSpec`, `DispatcherError` — `Dispatcher.swift`.
- `DispatcherRegistry.v1()` — the registry list; `.defaultDispatcherID` — what new cards are created with.
- `StreamJSONParser` — pure NDJSON → typed events; unit-tested.
- `TerminalLauncher` — AppleScript "open a terminal window running this command"; pure command/script builders are unit-tested, `launch` is `@MainActor`.

## Status & rules

- **iTerm hand-off semantics:** one `.log` event (moves the card to running), then immediate success with `resultText: "Opened in …"`, `exitCode`/`sessionID` nil. No tracking after hand-off — deliberately no `sessionID`, so Follow up / resume never appear on handed-off cards. The prompt travels by temp file (`$TMPDIR/VoxiTermPrompts`) read via `"$(cat …)"` — never on a command line; the shell `rm`s it after claude exits, and a 24 h sweep on each dispatch catches orphans.
- **`TerminalLauncher` targets apps by bundle id** and checks iTerm is installed **before** creating the script (instantiating an AppleScript that `tell`s a missing app fails); everything variable is `shellQuoted`, the whole command `escapedForAppleScript` (backslashes before quotes). NSAppleScript is main-thread-only — `execute` hops via `MainActor.run`. Automation denial (-1743) maps to a friendly per-app message.
- **Unknown stream-json event types/subtypes are silently skipped, never errors** — the claude CLI adds event types between versions (`rate_limit_event`, `system/status`, …).
- **Success = exit 0 ∧ a `result` event was seen ∧ `!is_error`.** Subtype can read "success" with `is_error` true on API errors; SIGTERM → exit 143 with **no** result event = cancelled/crashed, not failed-with-result.
- **Binary discovery order is load-bearing:** real paths (`~/.local/bin`, homebrew, `/usr/local/bin`) first, login-shell `which claude` **LAST** — the login shell resolves to a stale 1.0.113 on the dev machine. Everything `--version`-validated, major ≥ 2.
- `execute` must honor task cancellation: SIGTERM, then SIGKILL after 3 s grace.
- **Stall watchdog:** no stdout/stderr activity for `stallTimeout` (default 300 s) → the run is terminated through the cancel path and fails with a "stalled" result. Silence is the failure signal; wall-clock duration is not.
- **The cached binary is re-validated on every `locate()`** — the CLI self-updates in place, so the stored version re-probes via `--version` and a downgraded path falls through to a full probe.

## Gotchas

- `result.result` is Optional — null on `error_max_turns`.
- NDJSON lines can be hundreds of KB (a single assistant message) — no line-length assumptions.
- Completion resumes only after stdout EOF ∧ stderr EOF ∧ process exit (`maybeFinish` + resume-once lock) — resuming earlier loses late-buffered events.
- `Process` is non-Sendable: all handle access goes through `ProcessBox` (lock also closes the cancel-before-run race). `standardInput = FileHandle.nullDevice` (else ~3 s stall); `PATH` is force-set (launchd context has no user PATH).
- `extraFlags` is naïvely whitespace-split — no quoting support; it can conflict with built-in flags. Prefer first-class `DispatcherParamSpec`s over leaning on it.
- Real-binary integration test is env-gated and costs cents: `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 … -only-testing:VoxiTests/DispatchersIntegrationTests`.
