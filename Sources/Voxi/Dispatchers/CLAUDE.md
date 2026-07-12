# Dispatchers — Module Steering

**Pluggable executors for action cards; v1 ships exactly one: headless Claude Code.** Inherits the root invariants; subprocess platform rules in `steering/MACOS_PLATFORM.md`, Sendable patterns in `steering/CONCURRENCY.md`.

## Purpose & boundary

`Dispatcher` (protocol) + `DispatcherRegistry` are the extension seam — a new executor is one file + one registry line. `ClaudeCodeDispatcher` spawns `claude -p … --output-format stream-json`, parses NDJSON via `StreamJSONParser`, and streams `DispatchEvent`s upward. `ClaudeBinaryLocator` finds and version-gates the binary; `RecentDirectories` is the working-dir MRU. **`QueueRunner` (CommandQueue) is the only caller** — dispatchers never touch the DB or UI.

## Public surface

- `Dispatcher`, `DispatchEvent`, `DispatchResult`, `DispatcherParamSpec`, `DispatcherError` — `Dispatcher.swift`.
- `DispatcherRegistry.v1()` — the registry list.
- `StreamJSONParser` — pure NDJSON → typed events; unit-tested.

## Status & rules

- **Unknown stream-json event types/subtypes are silently skipped, never errors** — the claude CLI adds event types between versions (`rate_limit_event`, `system/status`, …).
- **Success = exit 0 ∧ a `result` event was seen ∧ `!is_error`.** Subtype can read "success" with `is_error` true on API errors; SIGTERM → exit 143 with **no** result event = cancelled/crashed, not failed-with-result.
- **Binary discovery order is load-bearing:** real paths (`~/.local/bin`, homebrew, `/usr/local/bin`) first, login-shell `which claude` **LAST** — the login shell resolves to a stale 1.0.113 on the dev machine. Everything `--version`-validated, major ≥ 2.
- `execute` must honor task cancellation: SIGTERM, then SIGKILL after 3 s grace.

## Gotchas

- `result.result` is Optional — null on `error_max_turns`.
- NDJSON lines can be hundreds of KB (a single assistant message) — no line-length assumptions.
- Completion resumes only after stdout EOF ∧ stderr EOF ∧ process exit (`maybeFinish` + resume-once lock) — resuming earlier loses late-buffered events.
- `Process` is non-Sendable: all handle access goes through `ProcessBox` (lock also closes the cancel-before-run race). `standardInput = FileHandle.nullDevice` (else ~3 s stall); `PATH` is force-set (launchd context has no user PATH).
- `extraFlags` is naïvely whitespace-split — no quoting support; it can conflict with built-in flags. Prefer first-class `DispatcherParamSpec`s over leaning on it.
- Real-binary integration test is env-gated and costs cents: `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 … -only-testing:VoxiTests/DispatchersIntegrationTests`.
