#!/usr/bin/env bash
# Start single-thread Qwen3-TTS HTTP server for Clicky.
#
# Usage:
#   ./scripts/start-qwen3-tts-http.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${REPO_ROOT}/.venv-qwen3-tts"
PORT="${QWEN3_TTS_HTTP_PORT:-8766}"
MODEL="${QWEN3_TTS_MODEL:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "Run ./scripts/setup-qwen3-tts-sidecar.sh first" >&2
  exit 1
fi

exec "${VENV}/bin/python" "${REPO_ROOT}/scripts/qwen3-tts-http-sidecar.py" \
  --host 127.0.0.1 \
  --port "${PORT}" \
  --api-key local \
  --model "${MODEL}" \
  --default-speaker Serena \
  --default-language Auto
