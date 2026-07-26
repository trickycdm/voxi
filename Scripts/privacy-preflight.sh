#!/bin/zsh
# privacy-preflight.sh — static privacy/security gate, run by release.sh stage 1.
#
#   ./Scripts/privacy-preflight.sh
#
# Enforces PRIVACY_AUDIT.md mechanically where a grep can:
#   HARD FAIL  — private/generated artifacts tracked in git; credential patterns
#                in tracked content; telemetry SDK imports.
#   WARN       — prints every network callsite and any log line interpolating
#                transcript-ish variables, for human review against the
#                allowlist in PRIVACY_AUDIT.md claim 7.
#
# Exit 0 = pass (possibly with warnings). Exit 1 = hard failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0
fail() { print -P "%F{red}FAIL:%f $1"; FAIL=1; }
warn() { print -P "%F{yellow}review:%f $1"; }
ok()   { print -P "%F{green}ok:%f $1"; }

# Exclude this script (it contains the patterns it hunts) and the audit doc.
SELF_EXCLUDE=(":(exclude)Scripts/privacy-preflight.sh" ":(exclude)PRIVACY_AUDIT.md")

# --- 1. Tracked files that must never be in git ------------------------------
FORBIDDEN_TRACKED=$(git ls-files -- \
  '*.sqlite' '*.sqlite-wal' '*.sqlite-shm' '*.dmg' '*.xcarchive' \
  'dist/*' 'build/*' 'plans/*' || true)
if [[ -n "$FORBIDDEN_TRACKED" ]]; then
  fail "private/generated artifacts tracked in git:\n$FORBIDDEN_TRACKED"
else
  ok "no private/generated artifacts tracked"
fi

# --- 2. Credential patterns in tracked content -------------------------------
CRED_PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{10,}'          # Anthropic API key
  'sk-[A-Za-z0-9]{20,}'                # OpenAI-style key
  'AKIA[0-9A-Z]{16}'                   # AWS access key
  'AIza[0-9A-Za-z_-]{35}'              # Google API key
  'xox[abps]-[0-9A-Za-z-]{10,}'        # Slack token
  'gh[pousr]_[A-Za-z0-9]{20,}'         # GitHub token
  'BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY'
)
CRED_HITS=""
for pattern in "${CRED_PATTERNS[@]}"; do
  HITS=$(git grep -I -n -E "$pattern" -- . "${SELF_EXCLUDE[@]}" || true)
  [[ -n "$HITS" ]] && CRED_HITS+="$HITS\n"
done
if [[ -n "$CRED_HITS" ]]; then
  fail "credential-shaped strings in tracked files:\n$CRED_HITS"
else
  ok "no credential patterns in tracked content"
fi

# --- 3. Telemetry / analytics SDKs -------------------------------------------
TELEMETRY=$(git grep -I -n -E \
  '^\s*import (Sentry|Firebase[A-Za-z]*|Mixpanel|PostHog|Amplitude|Segment|Bugsnag|Datadog[A-Za-z]*)' \
  -- 'Sources/' 'project.yml' || true)
TELEMETRY_PKG=$(git grep -I -n -iE 'sentry|firebase|mixpanel|posthog|amplitude|bugsnag|datadog' \
  -- 'project.yml' || true)
if [[ -n "$TELEMETRY$TELEMETRY_PKG" ]]; then
  fail "telemetry/analytics SDK reference found:\n$TELEMETRY\n$TELEMETRY_PKG"
else
  ok "no telemetry/analytics SDKs"
fi

# --- 4. Network surface (human review) ---------------------------------------
print ""
print "Network callsites in Sources/ — every line must be explainable by"
print "PRIVACY_AUDIT.md claim 7 (user-keyed refiners, model downloads, Sparkle):"
NETWORK=$(git grep -n -E 'URLSession|URLRequest|https?://' -- 'Sources/**/*.swift' || true)
if [[ -n "$NETWORK" ]]; then
  print "$NETWORK" | while IFS= read -r line; do warn "$line"; done
else
  ok "no network callsites in Sources/"
fi

# --- 5. Suspicious log interpolations (human review) -------------------------
SUSPECT_LOGS=$(git grep -n -E \
  'voxiLog\.[a-z]+\(.*\\\((transcript|rawTranscript|finalText|apiKey|anthropicAPIKey|openAIAPIKey)' \
  -- 'Sources/' || true)
if [[ -n "$SUSPECT_LOGS" ]]; then
  print "$SUSPECT_LOGS" | while IFS= read -r line; do warn "$line"; done
else
  ok "no log lines interpolating transcript/key variables"
fi

print ""
if (( FAIL )); then
  print -P "%F{red}privacy preflight FAILED%f"
  exit 1
fi
print -P "%F{green}privacy preflight passed%f"
