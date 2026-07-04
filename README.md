# Voxi

Local-first dictation for macOS with a voice Command & Control mode. Hold a key, speak,
release — polished text appears at the cursor of whatever app you're in. Or dictate a *task*,
watch it become an action card, and dispatch it to a headless Claude Code session.

Everything runs on-device (Apple Silicon): transcription via Parakeet (FluidAudio, default) or
WhisperKit, cleanup via a rule-based refiner that works fully offline — optionally enhanced by a
local LLM (Ollama / LM Studio / llama.cpp) or the Anthropic API with your key. No accounts, no
telemetry. Idle footprint ≈ 120 MB.

## Build & run

Requires Xcode 26+, XcodeGen (`brew install xcodegen`), macOS 14+.

```sh
xcodegen generate
xcodebuild -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Voxi.app
```

Tests (379, Swift Testing): fixtures first, then test.

```sh
./Scripts/make-test-audio.sh        # spoken WAV fixtures via `say` (gitignored)
xcodebuild -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build test
```

Headless pipeline harness (no mic or permissions needed; downloads the model on first run):

```sh
BIN=build/Build/Products/Debug/Voxi.app/Contents/MacOS/Voxi
$BIN --transcribe Tests/Fixtures/audio/simple.wav              # raw ASR
$BIN --dictate    Tests/Fixtures/audio/correction.wav          # ASR + refinement
$BIN --command    Tests/Fixtures/audio/command.wav             # ASR + card draft JSON
# engines: --engine parakeet|whisperkit [--model <id>]
```

Real-dispatcher integration test (spawns `claude -p`, costs a few cents):

```sh
TEST_RUNNER_VOXI_CLAUDE_INTEGRATION=1 xcodebuild -project Voxi.xcodeproj -scheme Voxi \
  -configuration Debug -derivedDataPath build test -only-testing:VoxiTests/DispatchersIntegrationTests
```

## Using it

- **fn (hold)** — push-to-talk dictation; release to insert. **Esc** cancels.
- **fn+Space** — hands-free toggle for long dictation.
- **fn+⌃ (hold)** — Command Mode: the dictation becomes an action card in the queue;
  edit its prompt, pick a working directory, click **Dispatch** to run it via
  `claude -p` with live logs on the card. Nothing runs without that click.
- All chords are configurable in Hub → Settings → Hotkeys. If the fn key triggers the
  system Globe action, set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing*
  (onboarding walks you through this).
- Menu bar → **Open Hub** for History (full-text search), personal Dictionary, and Settings
  (mic, ASR engine + model downloads, refiner backends, launch-at-login).

Permissions: **Microphone** (capture) and **Accessibility** (global hotkeys, text insertion).
Onboarding requests both with live re-checks. Dev note: ad-hoc signing means TCC grants can
reset after rebuilds — `tccutil reset Accessibility com.colin.voxi` if hotkeys go quiet.

## Architecture

Modules under `Sources/Voxi/`, one concern each, connected by small protocols so additions are
code-free or additive: `ASREngine` (new speech engine = one file + registry line), `Refiner`
(new cleanup backend), `Dispatcher` (new card executor). See `plans/voxi-v1/design.md` for the
locally-verified technical decisions (event-tap details, insertion tiers, claude stream-json).

```
Hotkeys → Capture → Transcription → Refinement → Insertion   (dictation)
                                              ↘ CommandQueue → Dispatchers (claude-code)
Pill (non-activating status panel)   Hub (history/dictionary/settings)   Persistence (GRDB+FTS5)
```
