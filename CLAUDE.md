# Voxi — Steering

Local-first dictation for macOS with a voice Command & Control mode. Hold a key, speak, release — text appears at the cursor; or dictate a task and dispatch it to a headless Claude Code session. Everything on-device except the optional user-keyed LLM refiner.

> Local-first, no telemetry. One event tap. Nothing dispatches without a click. The `.xcodeproj` is generated — edit `project.yml`.

This is the **canonical steering context** for the repo, loaded natively by Claude Code. The sibling `AGENTS.md` is a thin pointer back here. Keep this file at repo altitude — invariants, the map, and pointers. Module conventions live in each module's own `CLAUDE.md`; the doctrine behind this system is [`AI_NATIVE_REPO_STANDARDS.md`](AI_NATIVE_REPO_STANDARDS.md).

## Structure

```
Sources/Voxi/
  App/            — composition root (AppState), DictationCoordinator, headless CLIMode, @main
  Capture/        — mic → 16 kHz mono Float32 + ~30 Hz levels (AVAudioEngine tap)
  Hotkeys/        — the single CGEventTap; pure ChordStateMachine; permission polling
  Transcription/  — ASREngine protocol + registry; Parakeet (default), WhisperKit
  Refinement/     — Refiner protocol; RefinerChain falls back LLM → rules on any error
  Insertion/      — 3-tier text insertion (AX → pasteboard → AppleScript opt-in)
  Pill/           — floating non-activating status panel; pure PillTimingPolicy
  DesignSystem/   — "Racing Green & Cream" tokens: Theme.swift (colors/radii/spacing), brand views
  CommandQueue/   — ActionCard lifecycle, QueueRunner, queue UI
  Dispatchers/    — Dispatcher protocol + registry; claude-code executor, stream-json parsing
  Persistence/    — GRDB: history (+FTS5), dictionary, actionCard; append-only migrations
  Hub/            — settings/history/dictionary window
  Onboarding/     — first-run permission walkthrough (pure OnboardingModel)
Tests/VoxiTests/  — Swift Testing, in-process against the app binary
plans/            — plan.md + worklog.md per piece of work; steering/ = rules; docs/ = reference
```

Data flow, module table, decision log: [`docs/architecture.md`](docs/architecture.md). Product spec: `PROMPT.md`.

## Load-Bearing Invariants

**Adoption status (read before trusting a bullet as enforced):** this repo has **no CI**. The compile-time gate (`SWIFT_STRICT_CONCURRENCY: complete`) and the test suite are the only mechanical enforcement; everything else below is convention held by review and by these docs.

- **Local-first, no telemetry.** Audio, transcripts, history never leave the machine except to a user-configured LLM refiner backend or a user-dispatched claude run. Never log transcript content or API keys (`steering/CODING_CONVENTIONS.md`).
- **Nothing dispatches without an explicit user click.** Voice creates cards; only the Dispatch button runs them. Product safety rule — do not add auto-run paths.
- **Card status moves only through `CardStatus.canTransition`,** via `CardStore` helpers. Interrupted runs are reconciled to `failed` on launch.
- **Migrations are append-only** — never edit a registered migration; new columns nullable/defaulted (`steering/PERSISTENCE.md`).
- **Edit `project.yml`, never the `.xcodeproj`** — it's generated (and gitignored). Run `xcodegen generate` after changing it.
- **One `CGEventTap`, one pill panel, one queue window per app lifetime** — shown/hidden, never recreated, never `close()`d (`steering/MACOS_PLATFORM.md`).
- **Extension points are protocol + registry line:** new ASR engine, refiner backend, or card executor = one file + one registry entry, nothing else. If a change needs more, the seam is being broken.
- **Fallbacks never break dictation:** refiner falls back to rules on any error; insertion degrades tier-by-tier. The user's words must land.
- **Signing is never ad-hoc; the identity is per-config** (both team `F7H963S3B4`, set in `project.yml`): Debug = "Apple Development" (daily TCC grants key off it and must survive rebuilds), Release = "Developer ID Application" + hardened runtime (distribution; `Scripts/release.sh`). Never publish a DMG that did not come out of a green release.sh run — the site claims "notarised by Apple".
- **Updates ship via Sparkle 2** (Release builds only — Debug shares the bundle id and must not start the updater): `appcast.xml` on `main` is the live feed, items are EdDSA-signed and inserted only by release.sh, and `CFBundleVersion` must bump monotonically or updaters can't see the release (`docs/RELEASING.md`).

## Tooling

Requires Xcode 26+, XcodeGen (`brew install xcodegen`), macOS 14+.

```sh
xcodegen generate                                                       # after any project.yml change
xcodebuild -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build build
xcodebuild -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build test
./Scripts/make-test-audio.sh                                            # spoken WAV fixtures (needed before ASR tests)
build/Build/Products/Debug/Voxi.app/Contents/MacOS/Voxi --dictate <wav> # headless pipeline harness, no mic/permissions
./Scripts/release.sh X.Y.Z                                              # signed+notarised DMG in dist/ (docs/RELEASING.md)
```

- The CLI harness (`--transcribe` / `--dictate` / `--command`, `--engine parakeet|whisperkit`) is the pipeline's automated integration surface.
- Real-claude integration test (costs cents, env-gated): prefix the var with `TEST_RUNNER_` — xcodebuild strips the prefix inside the test process: `TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 xcodebuild … test -only-testing:VoxiTests/DispatchersIntegrationTests`.
- Mic, TCC, event-tap, and window behavior **cannot be tested headlessly** — those changes carry explicit manual verification steps (`steering/TESTING_AND_VERIFICATION.md`).

## Standards

Cross-cutting standards live in [`/steering`](steering) and are the authority for their topic — start there, don't re-derive conventions from the code:

- [`steering/CODING_CONVENTIONS.md`](steering/CODING_CONVENTIONS.md) — module structure, extension-point rule, error enums, logging + privacy, style, dependency hygiene.
- [`steering/CONCURRENCY.md`](steering/CONCURRENCY.md) — Swift 6 strict-concurrency playbook; **read before touching any framework callback** (a missing `@Sendable` crashed the app).
- [`steering/DESIGN_SYSTEM.md`](steering/DESIGN_SYSTEM.md) — "Racing Green & Cream" tokens and rules; **read before touching any UI color, radius, or spacing** — new UI color = token, never a literal.
- [`steering/MACOS_PLATFORM.md`](steering/MACOS_PLATFORM.md) — windows/panels, event tap, TCC, realtime audio, subprocess contracts.
- [`steering/PERSISTENCE.md`](steering/PERSISTENCE.md) — GRDB rules, append-only migrations, conformances, FTS5.
- [`steering/TESTING_AND_VERIFICATION.md`](steering/TESTING_AND_VERIFICATION.md) — pure-logic-extraction rule, when-to-test table, verify-before-done gate.

## Per-Module Steering

The five danger-zone modules carry their own `CLAUDE.md` (purpose, boundary, public surface, gotchas): `Capture/`, `Hotkeys/`, `Insertion/`, `Dispatchers/`, `CommandQueue/`. When working in one, that file is the authority for local rules. Other modules are covered by the root map; give one a `CLAUDE.md` only when sessions repeatedly stumble there — grow steering with the code.

## Writing CLAUDE.md

`CLAUDE.md` documents what code can't tell you: architecture, conventions, invariants, cross-module flow, the why behind non-obvious choices.

- **Don't duplicate code facts** (versions, schemas, signatures, tunables) — link to their authoritative home instead; copies drift.
- **Don't state aspirational architecture as current fact.** Nothing here is CI-enforced; mark targets as targets. Agents trust steering literally — an overclaim is a trap.
- **Keep every `CLAUDE.md` under 200 lines.** It's a map, not a manual; overflow goes to `steering/` or a nested `CLAUDE.md`.
- Update the relevant `CLAUDE.md`/steering doc in the same change that invalidates it. A stale steering doc is worse than none.

## Steering-Doc Convention

- **`CLAUDE.md` is canonical** at every altitude; **`AGENTS.md` is a thin pointer** for tools that look for it.
- **`steering/` holds prescriptive standards; `docs/` holds descriptive reference** (architecture rationale, decision log, open items).
- **Plans live in `plans/<YYYY-MM-DD>-<slug>/plan.md` + `worklog.md`** — plan is intent, worklog is the record.
- **Grow with the code, prune drift** — fix docs the moment code contradicts them.
