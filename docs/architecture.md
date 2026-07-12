# Voxi — Architecture Reference

Descriptive reference and decision log. Prescriptive rules live in [`../steering/`](../steering); the map is the root [`CLAUDE.md`](../CLAUDE.md). The original product spec is [`PROMPT.md`](../PROMPT.md); the M0 research detail behind many decisions is `plans/voxi-v1/design.md` (historical artifact — where it conflicts with this file, this file wins).

## The pipeline

```
Hotkeys → Capture → Transcription → Refinement → Insertion      (dictation)
                                              ↘ CommandQueue → Dispatchers   (command mode)
Pill (non-activating status panel)   Hub (history/dictionary/settings)   Persistence (GRDB+FTS5)
```

One voice session runs end-to-end through `DictationCoordinator`: a hotkey chord starts capture; release stops it; the 16 kHz mono buffer goes to the selected `ASREngine`; the transcript through the `RefinerChain`; the result is either inserted at the cursor (`TextInserter`, 3 tiers) or drafted into an `ActionCard` on the queue (command mode), which the user reviews and explicitly dispatches to a `Dispatcher` (v1: headless `claude -p`).

## Modules

| Module | Owns | Key seam |
|---|---|---|
| App | Composition root (`AppState`), `@main` scene, `DictationCoordinator`, headless `CLIMode` | Optional-closure hooks wire components |
| Capture | `AVAudioEngine` mic tap → 16 kHz mono Float32 + ~30 Hz levels | `CapturedAudio` out; one consumer per instance |
| Hotkeys | The single `CGEventTap`, chord persistence, permission polling | Pure `ChordStateMachine`; `AsyncStream<HotkeyEvent>` |
| Transcription | Pluggable ASR: Parakeet (default), WhisperKit | `ASREngine` protocol + `ASREngineRegistry` |
| Refinement | Transcript cleanup + card drafting; LLM optional, rules always | `Refiner` protocol + `RefinerChain` fallback |
| Insertion | 3-tier text insertion, secure-field refusal, smart formatting | `TextInserter`; probe-before-insert |
| DesignSystem | Color/radius/spacing tokens (asset catalog), RacingNumberDisc view (queue-position disc) | Theme.swift Color/NSColor accessors; plaque text style |
| Pill | Floating status panel (one `NSPanel` for app lifetime) | Pure `PillTimingPolicy` decides visibility |
| CommandQueue | `ActionCard` lifecycle, `QueueRunner`, queue UI | Validated `CardStatus` transitions via `CardStore` |
| Dispatchers | Card executors; claude binary discovery; stream-json parsing | `Dispatcher` protocol + `DispatcherRegistry` |
| Persistence | GRDB (`history` + FTS5, `dictionaryEntry`, `actionCard`) | Append-only migrations; Sendable records |
| Hub | Settings/history/dictionary window | — |
| Onboarding | First-run permission walkthrough (plain `NSWindow`, pre-scene) | Pure `OnboardingModel` step/gate logic |

Extension points: a new speech engine, refiner backend, or card executor is one file + one registry line (see `steering/CODING_CONVENTIONS.md`).

## Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-03 | ASR default = FluidAudio/Parakeet TDT 0.6B v3; WhisperKit second engine | Better WER (6.32% vs 7.44% for large-v3), ~190× realtime on ANE; WhisperKit covers long-tail languages and proves the `ASREngine` protocol |
| 2026-07-03 | GRDB over SwiftData | macOS 14 SwiftData = first-year bugs, no FTS5, non-Sendable `ModelContext` under strict concurrency |
| 2026-07-03 | XcodeGen; `.xcodeproj` generated and gitignored | Reviewable project config; edit `project.yml` only |
| 2026-07-03 | One `CGEventTap` for all chords; Accessibility permission only | A second tap doubles the per-keystroke cost; active tap needs no Input Monitoring |
| 2026-07-04 | KeyboardShortcuts package dropped | Cannot record modifier-only chords — every Voxi binding is one; replaced by a small custom recorder |
| 2026-07-04 | 3-tier insertion, probe **before** inserting | Tier-2 (pasteboard) failure is undetectable after the fact; Chromium returns AX `.success` without inserting, so AX writes verify caret advance (UTF-16) |
| 2026-07-04 | AppleScript paste is opt-in, never auto-fallback | Extra Automation permission + double-insert risk |
| 2026-07-04 | claude dispatch success rule: exit 0 ∧ result event present ∧ `!is_error` | Subtype can read "success" with `is_error` true; SIGTERM exits 143 with no result event (= cancelled, not failed) |
| 2026-07-04 | Binary discovery probes real paths first, login-shell `which` **last** | Login shell resolves to a stale claude 1.0.113 on the dev machine |
| 2026-07-04 | **Signing switched from ad-hoc to Apple Development (team F7H963S3B4)** | Ad-hoc identity changes every rebuild and TCC grants key off the identity — onboarding hung on a stale TCC entry. Supersedes the ad-hoc instruction in `plans/voxi-v1/design.md` |
| 2026-07-04 | Nothing auto-dispatches; cards run only on an explicit click | Product safety rule from the spec (`PROMPT.md`) |
| 2026-07-11 | AVFoundation callback closures must be `@Sendable` | Tap closure inherited `@MainActor` and trapped on the realtime queue — crashed on first live capture; now a steering rule (`steering/CONCURRENCY.md`) |
| 2026-07-11 | Onboarding mic test gets its own `AudioCapture` instance | The shared instance's single `onLevel` slot was stolen/nil'd by the mic test, killing the pill waveform (voxi-v2 M1) |
| 2026-07-12 | Colors in asset catalog, Theme.swift hand-written accessors (not codegen) | ~20 colors do not justify SwiftGen dependency; color names appear once; `RacingNumberDisc` is a non-adaptive brand view |
| 2026-07-12 | Pill forced to `.darkAqua` appearance | Floats over other apps' windows and must not inherit system appearance; adaptive tokens resolve dark inside it in both light and dark system themes |
| 2026-07-12 | Pill centering via frame-change observer on hosting view | NSHostingView's preferredContentSize resizes panel around fixed bottom-left origin; observer re-pins midX to screen centre; early-return inside observer prevents observer/setFrame loop |
| 2026-07-12 | Device-name label threads on PillController as a property | Pure `PillTimingPolicy` and its tests remain untouched; `InputDeviceNaming` helper in Capture mirrors AudioCapture.start's default-device fallback |
| 2026-07-12 | History list day-grouping: pure `HistoryDayGrouping` helper | Merges only adjacent same-day entries; FTS5 search results stay ungrouped and relevance-ranked |
| 2026-07-12 | CardStatus chip colors map to tokens in QueueView, unit-tested | Semantic color tokens decouple design from layout; status → color mapping moves from implicit to explicit |

## Open Items

- **Streaming partial transcription in the pill** — deferred to its own plan. Both engines' libraries support streaming (FluidAudio `StreamingAsrManager`, WhisperKit `AudioStreamTranscriber`) but Voxi's `ASREngine` protocol is batch-only and Parakeet streaming needs a different encoder model download.
- **Voice follow-up on a dispatched card** (dictate the next turn of a resumed session) — deferred; v2 ships button-based follow-up only.
- **Auto-open queue on card creation may become a setting** if it proves intrusive (v2 M2 ships it unconditionally).
- **Menu-bar badge for running/finished cards** — considered and rejected (2026-07-11).
- **LLM API keys live in UserDefaults, not Keychain** — accepted v1 tradeoff; revisit if the app is ever distributed.
- **Clipboard restore is a user toggle** — macOS 15.4+ shows pasteboard-read alerts; accepted tradeoff.
- **No CI** — the test suite, the strict-concurrency compile gate, and review are the only backstops today; invariants in `CLAUDE.md` are convention-enforced.
