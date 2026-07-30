#!/usr/bin/env bash
# Start single-thread Qwen3-ASR HTTP server (fixes MLX GPU stream threading bug).
#
# Usage:
#   ./scripts/start-qwen3-asr-http.sh
#   ./scripts/start-qwen3-asr-http.sh Qwen/Qwen3-ASR-1.7B

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${REPO_ROOT}/.venv-qwen3-asr"
PORT="${QWEN3_ASR_HTTP_PORT:-8765}"
MODEL="${1:-Qwen/Qwen3-ASR-0.6B}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "Missing venv. Run: ./scripts/setup-qwen3-asr-sidecar.sh" >&2
  exit 1
fi

exec "${VENV}/bin/python" "${REPO_ROOT}/scripts/qwen3-asr-http-sidecar.py" \
  --host 127.0.0.1 \
  --port "${PORT}" \
  --api-key local \
  --model "${MODEL}"
