#!/usr/bin/env bash
# Start Qwen3-ASR MLX live sidecar (fixed single-thread MLX + SSE).
#
# Endpoints:
#   GET http://localhost:17890/         — browser UI
#   GET http://localhost:17890/stream   — SSE transcript stream
#   GET http://localhost:17890/health   — health check
#
# Usage:
#   ./scripts/start-qwen3-asr-sse.sh
#   QWEN3_ASR_MODEL=Qwen/Qwen3-ASR-1.7B ./scripts/start-qwen3-asr-sse.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PYTHON="${REPO_ROOT}/.venv-qwen3-asr/bin/python"
PORT="${QWEN3_ASR_PORT:-17890}"
MODEL="${QWEN3_ASR_MODEL:-Qwen/Qwen3-ASR-0.6B}"

if [[ ! -x "${VENV_PYTHON}" ]]; then
  echo "Missing venv. Run: ./scripts/setup-qwen3-asr-sidecar.sh"
  exit 1
fi

# Stop broken TextStream instances on the same port.
pkill -f "textstream --no-browser --port ${PORT}" 2>/dev/null || true
pkill -f "qwen3-asr-live-sidecar.py --port ${PORT}" 2>/dev/null || true
sleep 0.5

echo "==> Starting Qwen3-ASR MLX live sidecar on port ${PORT}"
echo "    UI:     http://127.0.0.1:${PORT}/"
echo "    Stream: http://127.0.0.1:${PORT}/stream"
echo "    Model:  ${MODEL}"
echo ""

exec "${VENV_PYTHON}" "${REPO_ROOT}/scripts/qwen3-asr-live-sidecar.py" \
  --host 127.0.0.1 \
  --port "${PORT}" \
  --model "${MODEL}" \
  --interval 0.6 \
  --chunk-sec 1.0 \
  --finalization-mode latency \
  "$@"
