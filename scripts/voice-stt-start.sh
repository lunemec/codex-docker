#!/usr/bin/env bash
set -euo pipefail

mkdir -p /root/.openclaw/voice
pkill -f "voice_autotranscribe.py" >/dev/null 2>&1 || true

export WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-auto}"
export WHISPER_MODEL="${WHISPER_MODEL:-large-v3}"
export WHISPER_COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-int8}"
export WHISPER_BEAM_SIZE="${WHISPER_BEAM_SIZE:-5}"
export WHISPER_BEST_OF="${WHISPER_BEST_OF:-5}"
export VOICE_STT_POST_DISCORD="${VOICE_STT_POST_DISCORD:-1}"

nohup /opt/voice-stt/bin/python /usr/local/bin/voice_autotranscribe.py \
  > /root/.openclaw/voice/voice-stt.log 2>&1 &

echo "voice-stt started pid=$! model=${WHISPER_MODEL} lang=${WHISPER_LANGUAGE}"
