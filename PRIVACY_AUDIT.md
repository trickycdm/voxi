# Voxi Privacy Audit

Voxi's privacy claims, stated precisely enough to be verified against the code —
by a person or by an AI assistant. Don't trust the marketing copy; re-run the
audit below and append a dated result.

## The claims

| # | Claim | What must be true in the code |
|---|-------|-------------------------------|
| 1 | Dictation audio never leaves the machine | Capture (`Sources/Voxi/Capture/`) feeds ASR engines that run on-device (FluidAudio Parakeet, WhisperKit). No audio buffer reaches any network API. |
| 2 | Transcripts leave the machine only via user-configured backends | The only network calls in `Sources/` are the refiner backends (`AnthropicRefiner`, `OpenAICompatRefiner`), both inert until the user enters an endpoint/key, and user-dispatched claude CLI runs (subprocess of the user's own `claude` install, run only on an explicit Dispatch click). |
| 3 | Nothing dispatches without an explicit user click | Voice input only creates `ActionCard`s; `QueueRunner` executes a card exclusively from the Dispatch button path. No auto-run code path exists. |
| 4 | History and dictionary are local only | GRDB SQLite at `~/Library/Application Support/Voxi/voxi.sqlite`; no sync, no upload; history clearable in the Hub. |
| 5 | No telemetry, analytics, or crash-reporting SDKs | No such imports in `Sources/` or dependencies in `project.yml` (deps: WhisperKit, FluidAudio, GRDB, Sparkle). |
| 6 | Transcript content and API keys are never logged | Every `voxiLog` interpolation carries error descriptions, device metadata, or card IDs — never transcript text or key material (`steering/CODING_CONVENTIONS.md` rule). |
| 7 | The complete network surface is enumerable | (a) user-configured refiner endpoints; (b) one-time speech-model downloads from Hugging Face via WhisperKit/FluidAudio; (c) Sparkle appcast + DMG from GitHub (Release builds only); (d) user-dispatched claude runs. Nothing else. |

Known accepted tradeoffs (documented in `docs/architecture.md` Open Items): LLM API
keys live in UserDefaults, not Keychain (migration is a parked work item).

## Re-run the audit

Paste into Claude Code (or any code-capable assistant) at the repo root:

> Audit this repository against the seven claims in PRIVACY_AUDIT.md. For each
> claim: find every code path that could violate it (search for URLSession,
> URLRequest, http, Process/NSTask launches, os_log/Logger calls interpolating
> transcript or key variables, analytics SDK imports, and any write of audio or
> transcript data to network APIs). Report pass/fail per claim with file:line
> evidence, and list every network callsite you found. Then append a dated row
> to the Results section with the commit hash and your findings.

Enforcement between audits: `Scripts/privacy-preflight.sh` (run by
`Scripts/release.sh` before every release) mechanically blocks tracked secrets,
private artifacts, telemetry SDK imports, and unreviewed network callsites.

## Results

| Date | Commit | Auditor | Result |
|------|--------|---------|--------|
| 2026-07-26 | 155e903 | Claude Code (Fable 5) | All 7 claims pass. Network callsites in `Sources/`: `AnthropicRefiner.swift:20` (api.anthropic.com, user-keyed), `RefinerConfig.swift:26` + `RefinementSettings.swift:77` (localhost default for OpenAI-compat, user-configured). Model downloads and Sparkle occur via their libraries as claimed. Log audit: all `voxiLog` interpolations are error descriptions/metadata/IDs. No telemetry SDK imports. Dispatch path: `QueueRunner` runs cards only from the explicit Dispatch UI action. |
