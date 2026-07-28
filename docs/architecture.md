# Voxi — Architecture Reference

Descriptive reference and decision log. Prescriptive rules live in [`../steering/`](../steering); the map is the root [`CLAUDE.md`](../CLAUDE.md). The original product spec is [`PROMPT.md`](../PROMPT.md); the M0 research detail behind many decisions is `plans/voxi-v1/design.md` (historical artifact — where it conflicts with this file, this file wins).

## The pipeline

```
Hotkeys → Capture → Transcription → Refinement → Insertion      (dictation)
                                              ↘ CommandQueue → Dispatchers   (command mode)
Pill (non-activating status panel)   Hub (history/dictionary/settings)   Persistence (GRDB+FTS5)
```

One voice session runs end-to-end through `DictationCoordinator`: a hotkey chord starts capture; release stops it; the 16 kHz mono buffer goes to the selected `ASREngine`; the transcript through the `RefinerChain`; the result is either inserted at the cursor (`TextInserter`, 3 tiers) or drafted into an `ActionCard` on the queue (command mode), which the user reviews and explicitly dispatches to a `Dispatcher` — interactive hand-off to an iTerm/Terminal window running `claude` (the default), or headless `claude -p` with streamed logs.

## Modules

| Module | Owns | Key seam |
|---|---|---|
| App | Composition root (`AppState`), `@main` scene, `DictationCoordinator`, headless `CLIMode`, `UpdaterController` (Sparkle 2, Release-only) | Optional-closure hooks wire components |
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
| Onboarding | First-run permission walkthrough + speech-model download (plain `NSWindow`, pre-scene) | Pure `OnboardingModel` step/gate logic; reuses Hub's `SpeechModel` observable |

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
| 2026-07-18 | Hub sidebar replaced by the Pit Wall rail; `.hiddenTitleBar` window | NavigationSplitView's sidebar can't take a brand ground on macOS 14 and its toolbar/search chrome fought the full-bleed design. Rail pins dark via `.environment(\.colorScheme, .dark)` so existing adaptive tokens resolve Night Race (two new tokens only: `voxiRacing`, `voxiRailSelection`); relocated pane controls live in `HubPaneHeader`; min window width 820 (rail 196 + History split 620) |
| 2026-07-19 | Updater = Sparkle 2, GitHub-only appcast (`appcast.xml` on `main`, enclosures = release assets) | Zero site-repo coupling; repo is public so the raw URL is a free CDN feed; sandbox is off so no XPC complexity. EdDSA key in login Keychain only; Release-only start (Debug shares bundle id and must not write Sparkle defaults) |
| 2026-07-19 | Dispatch stall watchdog is inactivity-based (300 s silence), not a wall-clock cap | Long claude runs are legitimate; a healthy run streams events continuously. Terminates via the existing cancel path so completion semantics stay single-pathed |
| 2026-07-19 | Command mode gets its own `VoxiCommand` signal-red token (was: alias of Success mint) | The mint tint proved invisible in practice ("queue is broken" report was a missed chord); status colors stay reserved for status per the design system |
| 2026-07-18 | Secure-input refusal is holder-aware, not flag-global | `IsSecureEventInputEnabled()` is machine-global; MDM agents hold it session-long, which killed all insertion on a managed Mac. `SecureInput` reads the holder PID from IORegistry `IOConsoleUsers` (must use `IORegistryGetRootEntry`; the `IOService:/` path form lacks the property) and refuses only when the holder is the target app or unidentifiable. `AXSecureTextField` subrole still always refuses |
| 2026-07-20 | "Check for Updates" moved from tray menu to Hub rail footer | Voxi is an LSUIElement (accessory) app and Sparkle's update-status alerts could fail to front over it, making the check appear non-functional. The Hub rail is a user-controlled surface where we show inline status and drive Sparkle's install flow. Debug builds still disable the updater (unchanged invariant); control shows disabled with explanatory tooltip |
| 2026-07-26 | Privacy preflight gate + PRIVACY_AUDIT.md claims register | Ghost-pepper-inspired (MIT): release.sh stage 1 runs `Scripts/privacy-preflight.sh` (hard-fail on tracked artifacts/credentials/telemetry SDKs, print network surface for review); the audit doc carries a re-runnable prompt + dated results |
| 2026-07-26 | On-device refiner backend: `RefinerBackendID.localLLM`, obra/LLM.swift pinned by revision | GGUF Qwen via llama.cpp; anti-chatbot prompt + few-shots lifted from ghost-pepper (MIT). `LocalLLMEngine` is a deliberate singleton actor — `RefinerChain` is rebuilt per dictation inside the factory, which has no composition-root access; llama's backend is process-global anyway. The non-Sendable `LLM` lives inside an `@unchecked Sendable` box whose methods are the only touch points (strict-concurrency clean). CLI builds now need `-skipMacroValidation` (LLM.swift ships macros) |
| 2026-07-26 | Local refiner default model = Qwen 3.5 **2B** (not 0.8B); thinking suppressed; `refineCard` throws to rules | Empirical: 0.8B/suppressed only does light punctuation — parrots fillers and ignores "scratch that" even with few-shots in context; 0.8B/thinking cleans properly but takes ~15 s. 2B/suppressed does real cleanup in 0.5-1.2 s warm. Card JSON from small quantized models is unreliable and a failed attempt costs the 15 s timeout, so command mode falls to `RefinementRules.draftCard` instantly. CLI paths `_exit` after flushing — llama's Metal teardown can assert in atexit |
| 2026-07-28 | Interactive iTerm hand-off dispatcher (`claude-code-iterm`) is the default for new cards | Most dictated tasks need an interactive session; hand-off = one log event → immediate success, no sessionID recorded (interactive session ids are unknowable, so resume actions honestly never appear). Prompt travels by temp file read via `"$(cat …)"` — never on a command line; headless dispatcher unchanged for tracked runs |
| 2026-07-26 | Post-insert correction learning (ghost-pepper pattern, MIT) | After a dictation lands, `PostInsertObserver` polls the target field ≤15 s (1 s interval, 2-poll quiescence, aborts on app switch); `CorrectionInference` diffs by shared word prefix/suffix with hard guards (≤2 words/side, not punctuation-only, wrong must appear in inserted text) so only narrow name/term fixes are learned — into the existing dictionary as term+variant, giving free review/delete UX in the Hub. Toggle `learnCorrections` default on; field reads never logged. Learned pairs feed rules `enforceDictionary` AND the refiner vocabulary, so surrounding punctuation is trimmed from pairs |
| 2026-07-26 | `.auto` tier selection: no-element path duck-types the menu bar; clipboard fallback instead of blind ⌘V | Previously element-nil fell straight to a synthetic ⌘V into who-knows-what. Now `AXFocus.hasEnabledPasteMenuItem` (enabled ⌘V item, no extra modifiers) gates tier 2; a paste-incapable app gets the text left on the clipboard (`writeForUser`, NOT transient-marked) + a self-explaining `noPasteTarget` error — the user's words always land somewhere they control. Element-present paths are unchanged (probe deliberately not consulted). `AXFocus.fullText` gained an AXTextMarker fallback for WebKit readback |
| 2026-07-26 | Clipboard fallback gets **no dedicated toggle** | Toggle audit outcome: the probe/fallback only runs in `.auto`; "Clipboard paste (⌘V) always" in the method picker already bypasses it entirely, and the behavior it replaced was a blind ⌘V into apps with no paste target — there is no defensible "give me the old broken behavior" setting. Local refiner (backend picker) and correction learning (`learnCorrections`, default on) are the opt-in surfaces |
| 2026-07-26 | Refinement settings save split: picker + model auto-save, credentials keep explicit Save | Selecting a model row looked active but did nothing until Save — a trap. Backend/`localModelID` aren't credentials, so they persist on change (`RefinementModel.autoSavePickerChanges`, which deliberately does NOT commit a half-typed key on a backend flip); `isDirty`/Save now covers only credential fields, and the Save button renders only for credential backends |
| 2026-07-26 | Onboarding gained refiner + corrections steps (between speech model and hotkeys) | The two new features needed discovery + informed consent: the refiner step is opt-in (Next **is** "not now"; gate locks only mid-download; config saved on download success so the choice survives bail-out, then the engine prewarms); the corrections step is the long-form consent for the default-on learning toggle, applied to the live `TextInserter` so it takes effect the same session |
| 2026-07-26 | AppDelegate-owned controllers reach SwiftUI views by injection only (closure or `.environment`), never `NSApp.delegate as? AppDelegate` | Under `@NSApplicationDelegateAdaptor`, SwiftUI installs its own wrapper as `NSApp.delegate`, so the cast fails silently — it no-opped "Run Onboarding Again" (0.4.1 fix) and hid the rail's Check-for-Updates control entirely from 0.3.x to 0.4.2. `VoxiApp` holds the real delegate: menu gets a `showOnboarding` closure, the Hub gets `.environment(appDelegate.updater)` |
| 2026-07-26 | Learned corrections get a visible history: `learnedCorrection` log table (v3) + Dictionary-pane "Learned Corrections" list | 0.4.0 folded learned pairs invisibly into dictionary entries — users couldn't see what learning had done (and onboarding promised they could). The log table (wrong/right NOCASE-unique pair + `learnedAt`; re-learn bumps the date) records history without touching the dictionary schema; enforcement still lives in the entry. Deleting a learned row **unlearns** (strips the variant, keeps the bare term — it may be manual); deleting an entry cascades its learned rows. Pre-0.4.1 pairs have no rows — history starts empty |
| 2026-07-20 | Onboarding gained a speech-model download step | First-run previously required opening the Hub and manually downloading Parakeet before dictation worked. `Step.speechModel` (inserted between micTest and hotkeys) gates on `modelReady`, reuses the Hub's `SpeechModel` observable for catalog/download/progress, and is a strict gate (no skip, window closable). Explicit user click to start; ~600 MB download is not auto-started |

## Open Items

- **Streaming partial transcription in the pill** — deferred to its own plan. Both engines' libraries support streaming (FluidAudio `StreamingAsrManager`, WhisperKit `AudioStreamTranscriber`) but Voxi's `ASREngine` protocol is batch-only and Parakeet streaming needs a different encoder model download.
- **Voice follow-up on a dispatched card** (dictate the next turn of a resumed session) — deferred; v2 ships button-based follow-up only.
- **Auto-open queue on card creation may become a setting** if it proves intrusive (v2 M2 ships it unconditionally).
- **Menu-bar badge for running/finished cards** — considered and rejected (2026-07-11).
- **LLM API keys live in UserDefaults, not Keychain** — accepted v1 tradeoff. The app is now publicly distributed (2026-07-19), so this bill is due: parked as its own piece of work, not blocking the first release (the key is optional and user-supplied).
- **Clipboard restore is a user toggle** — macOS 15.4+ shows pasteboard-read alerts; accepted tradeoff.
- **No CI** — the test suite, the strict-concurrency compile gate, and review are the only backstops today; invariants in `CLAUDE.md` are convention-enforced.
