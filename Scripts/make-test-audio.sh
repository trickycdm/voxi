#!/bin/zsh
# Generate spoken WAV fixtures (16 kHz mono PCM, what ASR engines expect)
# so the transcription layer can be tested without a live microphone.
set -euo pipefail

DIR="${1:-$(dirname "$0")/../Tests/Fixtures/audio}"
mkdir -p "$DIR"

gen() { # gen <name> <text> [voice]
  local name="$1" text="$2" voice="${3:-Samantha}"
  local aiff="$DIR/$name.aiff"
  say -v "$voice" -o "$aiff" "$text"
  ffmpeg -y -loglevel error -i "$aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$DIR/$name.wav"
  rm "$aiff"
  echo "made $DIR/$name.wav"
}

gen simple "Hello world, this is a test of the transcription system."
gen filler "Um, so I think, uh, we should probably, um, refactor the parser."
gen correction "Send the report to John. Actually, scratch that. Send the report to Sarah instead."
gen dictation "The quick brown fox jumps over the lazy dog. New paragraph. Testing punctuation, capitalization, and flow."
gen command "Create a new web app that tracks my climbing sessions. Use Next JS. Keep it simple. Put it in my repos folder."

# 3 seconds of silence — hallucination-guard fixture
ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le "$DIR/silence.wav"
echo "made $DIR/silence.wav"
