# Testing & Verification

> _Cross-cutting standard — how we test, how we verify a change is done, and what review focuses on. Voxi uses Swift Testing (`@Suite`/`@Test`), 379 tests at last count, running in-process against the app binary. Bundled as one discipline: write the test, prove it works, review the diff._

## Testing

- **Framework: Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) — not XCTest. Suites group by module (`CommandQueueRunnerTests`, `PersistenceTests`); shared setup lives in private `Harness` structs inside the suite, and collaborators are faked via the module's small protocols (e.g. a fake `Dispatcher` / `DispatcherResolving` in the runner tests).
- **The pure-logic-extraction rule — the load-bearing pattern of this codebase.** Decisions are factored into pure, system-API-free types and tested exhaustively there: `ChordStateMachine` (hotkeys), `PillTimingPolicy` (pill show/hide), `RefinementRules`, `SmartFormatter`, `QueueLogic`, `MicTestGate`, `CLIMode.parse`. **New features must follow it**: if a behavior needs a mic, a window, an event tap, or a subprocess to test, extract the decision into a pure type first and test that. The thin shell around it gets manual verification instead.
- **Audio fixtures** are generated, not committed: run `./Scripts/make-test-audio.sh` (uses `say` + `ffmpeg`) before ASR-touching test runs.
- **Integration test with the real `claude` binary** is env-gated and costs money: `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 xcodebuild … test -only-testing:VoxiTests/DispatchersIntegrationTests`. Gotcha: xcodebuild only forwards env vars prefixed `TEST_RUNNER_` (the prefix is stripped inside the test process — the code checks `VOXI_CLAUDE_INTEGRATION`).
- **The headless CLI harness is the pipeline's integration surface** — no mic or permissions needed: `Voxi.app/Contents/MacOS/Voxi --transcribe|--dictate|--command <wav> [--engine parakeet|whisperkit]`. Use it to verify ASR/refinement/card-drafting changes end-to-end.

### When to test

| Change type | Required coverage |
| --- | --- |
| Pure-logic type (state machine, policy, rules) | Unit tests: happy path + edge cases + at least one hostile input |
| New persisted field / migration | Round-trip test + previous-version upgrade test |
| Dispatcher / stream parsing | Unit tests over the pure parts (args builder, parser) + gated integration test when behavior with the real binary changes |
| Bug fix | **Regression rule, no exceptions:** a test that fails without the fix and passes with it |
| Mic / TCC / window / tap behavior | Pure-extracted decisions unit-tested; the shell gets a listed manual verification step |

### Test discipline

- **Behavioural, not implementation.** Assert outputs and effects, not internals. A test that breaks on a valid refactor is testing the wrong thing.
- **Fix bugs, never work around them in tests.** A test that passes by avoiding the real interaction is hiding a production bug.

## Verification before completion

1. `xcodegen generate` (if project.yml changed) → `xcodebuild … build` — zero errors, zero new warnings (strict concurrency warnings are bugs).
2. `xcodebuild … test` — full suite, not just the new tests.
3. **Self-review the diff** with hostile inputs in mind: edge cases, error paths at system boundaries, isolation annotations on new closures, duplication of existing helpers.
4. **Prove the feature works, not just the code.** Pipeline changes: run the CLI harness. UI/capture/hotkey changes: run the app and exercise the flow (dictate, dispatch, watch the pill). If a step needs a human (permission grant, live mic), list it explicitly as a manual step — never claim it verified.

## Review focus

- **Logic correctness** — walk edge cases, not the happy path.
- **Isolation correctness** — every new framework callback annotated per `steering/CONCURRENCY.md`.
- **Platform contracts** — window lifecycle, tap rules, TCC per `steering/MACOS_PLATFORM.md`.
- **Duplication** — does a pure helper or store method already exist?
- **Data integrity** — migrations append-only, conformances updated in the same change, status transitions validated.
