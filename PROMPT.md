# Build Voxi — a local-first Wispr Flow clone for macOS with a voice Command & Control mode

## Why this exists

I'm building Voxi for myself: a native macOS dictation app that replicates the Wispr Flow experience (https://wisprflow.ai) but runs transcription locally on Apple Silicon, plus one feature Wispr doesn't have — a **Command & Control mode** where I dictate things I want *done*, they queue up as reviewable action cards, and I dispatch each card to an executor (the first executor is a headless Claude Code session). Think of it as a voice-driven command center sitting on top of a best-in-class dictation app.

Wispr's documented weaknesses are Voxi's design goals: Wispr is cloud-only (privacy backlash, network latency, no offline), heavy (~800MB RAM idle), and subscription-gated. Voxi is local-first, lightweight, native Swift, and mine.

## The product

### Mode 1 — Dictation (the Wispr clone)

The core loop: **hold a hotkey → speak → release → polished text appears at the cursor in whatever app is focused.** No window, no copy-paste. This loop is the product; everything else supports it.

**Capture & hotkeys**
- Push-to-talk: hold a global hotkey (default `Fn`, but `Ctrl+Opt` must work too since `Fn` requires low-level event-tap handling). Recording starts on press, stops on release.
- Hands-free toggle: a second hotkey (default `Fn+Space`) toggles recording on/off for long-form dictation.
- `Esc` cancels an in-progress dictation and discards it.
- All hotkeys user-configurable in Settings (the `KeyboardShortcuts` Swift package is the community-standard way to get a configurable-hotkey UI; use it unless you find a real reason not to).

**Transcription — local, always, and pluggable**
- On-device ASR on Apple Silicon. No audio ever leaves the machine for transcription.
- The ASR layer is a first-class **engine protocol**, not a hardcoded dependency: an engine declares its identity, its available models, and a transcribe interface (streaming where the engine supports it). Ship **two engines in v1** to prove the abstraction is real: **WhisperKit** (Swift-native, CoreML/ANE) and one of **Parakeet via FluidAudio** (fastest, current accuracy favorite in the open-source scene) or **whisper.cpp** (Metal-accelerated, runs any GGUF Whisper model). Pick the better-performing one as the default.
- **User-selectable models within each engine**: Settings gets an ASR section where I pick the engine and the model (e.g. Whisper tiny → large-v3-turbo variants), with download/manage support for model files (show size, download progress, delete). Model files live in Application Support. Adding a new model someone publishes should mean dropping in a file or picking it from a list — never a code change; adding a whole new engine should mean implementing the protocol and nothing else.
- Guard against the classic Whisper failure mode: silence or a wrong/low-signal mic (e.g. Bluetooth in a pocket) producing hallucinated text. Detect low input level and warn instead of injecting garbage. Show the active input device prominently.

**Cleanup & formatting pass**
- After transcription, a formatting pass removes filler words ("um", "uh"), fixes punctuation and capitalization, and applies self-correction handling ("actually, scratch that — say X" keeps only X).
- Implement this as a pluggable "refiner" step with three backends behind one protocol: (1) rule-based (always available, zero dependencies), (2) **local LLM via any OpenAI-compatible endpoint** — user supplies a base URL and model name, which covers Ollama, LM Studio, and llama.cpp servers out of the box, (3) Anthropic API with a user-supplied key (use `claude-haiku-4-5-20251001` for speed/cost; model id configurable). Settings lets me choose the backend and test the connection. The app must work fully offline with the rule-based refiner — LLM passes are an enhancement, never a requirement, and the local-LLM path keeps even the enhanced experience fully offline.
- Personal dictionary: user-managed list of names/acronyms/jargon fed to the transcriber/refiner so my terms come out spelled right.

**Text insertion — the hard part, get it right**
- Three-tier fallback, the pattern every serious open-source clone converged on:
  1. Accessibility API direct insertion into the focused element (cleanest, no clipboard side effects),
  2. clipboard write + synthesized `Cmd+V` via CGEvent, restoring the prior pasteboard contents afterward,
  3. AppleScript keystroke as last resort.
- Smart insertion: read the surrounding text of the focused field via the Accessibility API and adjust — lowercase the first word when inserting mid-sentence, manage leading/trailing spaces. This detail is a large part of why Wispr feels magical; don't skip it.

**The pill (floating indicator)**
- A small floating pill near the bottom-center of the screen (non-activating panel: it must never steal focus from the app being dictated into, and must float above full-screen-adjacent contexts where possible).
- States: idle (subtle) → recording (waveform animation reacting to input level, with cancel ✕ and done ✓ affordances) → processing (brief) → back to idle.
- Wispr's pill has documented bugs (fails to appear, gets stuck, leaves a black rectangle). Make the pill's show/hide lifecycle deliberately robust — it should be impossible to strand it in a stuck state.

**Shell**
- Menu bar app (`MenuBarExtra`/`NSStatusItem`), no Dock icon by default. Launch-at-login as an *opt-in* setting (Wispr forces it; don't).
- A main "Hub" window: searchable dictation History (every transcript kept locally), Dictionary management, and Settings (hotkeys, mic selection, refiner/LLM config, launch-at-login).
- First-run onboarding that walks through the two required permissions — **Microphone** and **Accessibility** (and Input Monitoring if the event-tap approach requires it) — with live re-checks so the user can't proceed in a broken state, then a mic test with a live level meter, then hotkey choice.

### Mode 2 — Command & Control (the new thing)

A third global hotkey (default `Fn+Ctrl`, configurable) enters **Command Mode**. Same hold-to-talk capture, but instead of inserting text at the cursor, the dictation becomes an **Action Card** in a queue.

**The flow**
1. I hold the command hotkey and say something like *"Create a new web app that tracks my climbing sessions, Next.js, keep it simple, put it in my repos folder."*
2. The raw transcript is refined into a structured card: a short **title**, a one-line **summary**, and a fully written-out **goal/prompt** — the dictation rewritten as a clear, self-contained instruction an agent could execute (this is where the LLM refiner earns its keep — local or Anthropic backend, whichever is configured; with no LLM backend configured, fall back to using the cleaned transcript verbatim and say so on the card).
3. The card appears in the **Queue** — a panel (own window or expanded pill view, your call, but it must be quickly summonable and dismissible) showing cards newest-first.
4. Each card shows: title, summary, the full prompt (editable before dispatch), the chosen dispatcher, dispatcher parameters (e.g. working directory), and a **Dispatch** button.
5. Cards move through a lifecycle: `queued → dispatched → running → succeeded / failed`, with status visible on the card and output/logs inspectable per card. Cards persist across app restarts.

**Dispatchers — pluggable executors**
- Define a small dispatcher protocol (id, display name, parameter schema, execute(card) with streaming status/log callbacks) so new executors are additive.
- **v1 ships one dispatcher: Claude Code headless.** It runs `claude -p "<refined prompt>"` (plus sensible flags for non-interactive use, e.g. `--output-format stream-json` for progress and `--permission-mode acceptEdits` — check `claude --help` on this machine and use what's actually supported) as a subprocess in a user-chosen working directory. Card params: working directory (directory picker with recent-dirs memory), optional extra CLI flags. Stream stdout into the card's log view; exit code determines succeeded/failed.
- Design the protocol so obvious future dispatchers (arbitrary shell command, "open URL", "append to a note") would slot in, but **do not build them** — one excellent dispatcher, not three stubs.

**Safety**
- Nothing executes without an explicit click on Dispatch. Voice queues work; hands approve it. No auto-dispatch in v1.

## Technical constraints

- **Native Swift + SwiftUI (AppKit where needed for panels/event taps).** Not Electron, not Tauri — resource footprint and native feel are core goals.
- Target macOS 14+, Apple Silicon.
- Xcode project buildable and runnable via `xcodebuild` from the CLI. Verify the toolchain on this machine before writing code and adapt to what's installed.
- Persistence: something simple and local (SwiftData or SQLite/GRDB — your call) for history, dictionary, and action cards.
- No accounts, no telemetry, no network calls except the optional user-keyed Anthropic API refiner.
- Code quality bar: this will be a long-lived personal tool. Match idiomatic Swift/SwiftUI conventions; keep the module boundaries clean (capture / transcription / refinement / insertion / command-queue / dispatchers are separate concerns).

## How to work

- Start by scoping: check the machine's toolchain (Xcode, Swift version, `claude` CLI presence and flags), then write a plan into `plans/voxi-v1/plan.md` with milestones, and keep a `worklog.md` beside it — one line per meaningful step. If an approach fails, log a RE-PLAN entry and edit the plan in place rather than creating a new one.
- Build in vertical slices that each end runnable:
  1. Menu bar shell + hotkey + audio capture + local transcription printed to log,
  2. text insertion + pill UI (the complete dictation loop),
  3. refinement pass + dictionary + history/Hub,
  4. Command Mode + queue + Claude Code dispatcher,
  5. onboarding/permissions polish + settings.
- **Verify as you go, against the real thing.** After each slice, build and launch the app and exercise the flow (dictation can be tested with generated/spoken audio files fed to the transcription layer where a live mic isn't scriptable; text insertion can be verified against TextEdit). At the end of each milestone, run a fresh-context verifier subagent against this spec and fix what it finds before moving on. Unit-test the pure logic (refinement rules, smart-insertion casing/spacing decisions, card lifecycle, pasteboard restore).
- Permissions (Accessibility, Microphone) can't be granted programmatically. When you hit a wall that genuinely needs me — granting a permission, testing live mic capture, an App-Sandbox/signing decision — finish everything else you can first, then stop with a short list of exactly what you need and how to test what you've built.
- Don't gold-plate: no per-app tone styles, no snippets, no multilingual UI, no screen OCR, no auto-updater in v1. They're deliberate cuts, not oversights. The bar for done is: I can dictate into any app as fluidly as Wispr, and I can dictate a task, watch it become a card, click Dispatch, and see Claude Code build it.

## Done means

1. Hold hotkey, speak into any macOS app, release — clean text at the cursor, fully offline.
2. Toggle mode works for long dictation; Esc cancels; the pill never gets stuck.
3. History, dictionary, and settings work in the Hub.
4. Command hotkey → dictated task → refined action card in the queue → edit → Dispatch → `claude -p` runs in my chosen directory with live status and logs on the card → card ends succeeded or failed.
5. Cards and history survive an app restart.
6. Idle footprint is a fraction of Wispr's reported ~800MB.
