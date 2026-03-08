#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: voice-stt-once <audio-file>" >&2
  exit 1
fi

AUDIO_PATH="$1"
if [[ ! -f "$AUDIO_PATH" ]]; then
  echo "File not found: $AUDIO_PATH" >&2
  exit 1
fi

WHISPER_MODEL="${WHISPER_MODEL:-large-v3}"
WHISPER_COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-int8}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-auto}"
WHISPER_BEAM_SIZE="${WHISPER_BEAM_SIZE:-5}"
WHISPER_BEST_OF="${WHISPER_BEST_OF:-5}"

/opt/voice-stt/bin/python - <<'PY' "$AUDIO_PATH" "$WHISPER_MODEL" "$WHISPER_COMPUTE_TYPE" "$WHISPER_LANGUAGE" "$WHISPER_BEAM_SIZE" "$WHISPER_BEST_OF"
import sys
from faster_whisper import WhisperModel

path, model_name, compute_type, language, beam_size, best_of = sys.argv[1:7]
model = WhisperModel(model_name, device="cpu", compute_type=compute_type)
kwargs = {"vad_filter": True, "beam_size": int(beam_size), "best_of": int(best_of)}
if language and language.lower() != "auto":
    kwargs["language"] = language
segments, _ = model.transcribe(path, **kwargs)
text = " ".join(seg.text.strip() for seg in segments).strip()
print(text or "(No speech detected)")
PY
