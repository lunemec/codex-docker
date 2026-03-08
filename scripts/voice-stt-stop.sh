#!/usr/bin/env bash
set -euo pipefail
pkill -f "voice_autotranscribe.py" >/dev/null 2>&1 || true
echo "voice-stt stopped"
