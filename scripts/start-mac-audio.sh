#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/start-mac-audio.sh <windows-host-or-ip> [port]"
  echo "Example: scripts/start-mac-audio.sh 192.168.1.6 5055"
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOWS_HOST="$1"
PORT="${2:-5055}"
AUDIO_MODE="${AUDIO_MODE:-lowLatency}"
AUDIO_LATENCY_MS="${AUDIO_LATENCY_MS:-50}"
AUDIO_VOLUME="${AUDIO_VOLUME:-1.0}"

exec swift run \
  --package-path "$ROOT_DIR/mac-controller" \
  mac-controller "$WINDOWS_HOST" "$PORT" \
  --audio-only \
  --audio-mode "$AUDIO_MODE" \
  --audio-latency-ms "$AUDIO_LATENCY_MS" \
  --volume "$AUDIO_VOLUME"
