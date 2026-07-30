#!/usr/bin/env bash
# Start local backends for Clicky, then open Xcode.
#
# Prerequisites:
#   1. Xcode → Settings → Accounts → sign in with Apple ID
#   2. worker/.dev.vars with API keys (copy from .dev.vars.example)
#   3. In Xcode: leanring-buddy target → Signing → select your Team → Cmd+R
#
# Usage:
#   ./scripts/run-clicky-local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

VENV="${REPO_ROOT}/.venv-qwen3-asr"
QWEN3_PORT="${QWEN3_ASR_HTTP_PORT:-8765}"
QWEN3_TTS_PORT="${QWEN3_TTS_HTTP_PORT:-8766}"
PI_GEMINI_PORT="${PI_GEMINI_PROXY_PORT:-4141}"
WORKER_PORT=8787

cleanup() {
  echo ""
  echo "==> Stopping background services..."
  pkill -f "qwen3-asr-http-sidecar.py --host 127.0.0.1 --port ${QWEN3_PORT}" 2>/dev/null || true
  pkill -f "qwen3-tts-http-sidecar.py --host 127.0.0.1 --port ${QWEN3_TTS_PORT}" 2>/dev/null || true
  pkill -f "packages/ai-server/dist/main.js" 2>/dev/null || true
  rm -f /tmp/clicky-pi-ai-server.pid 2>/dev/null || true
  pkill -f "mlx-qwen3-asr serve --port ${QWEN3_PORT}" 2>/dev/null || true
  pkill -f "wrangler dev" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> [1/5] Qwen3-ASR MLX HTTP server (STT) on :${QWEN3_PORT}"
if [[ -x "${VENV}/bin/python" ]]; then
  if ! curl -sf "http://127.0.0.1:${QWEN3_PORT}/health" >/dev/null 2>&1; then
    "${VENV}/bin/python" "${REPO_ROOT}/scripts/qwen3-asr-http-sidecar.py" \
      --host 127.0.0.1 \
      --port "${QWEN3_PORT}" \
      --api-key local \
      --model Qwen/Qwen3-ASR-0.6B \
      >/tmp/clicky-qwen3-http.log 2>&1 &
    echo "    Starting (first run downloads model, see /tmp/clicky-qwen3-http.log)..."
    for _ in $(seq 1 120); do
      if curl -sf "http://127.0.0.1:${QWEN3_PORT}/health" >/dev/null 2>&1; then
        echo "    Ready: http://127.0.0.1:${QWEN3_PORT}/health"
        break
      fi
      sleep 2
    done
  else
    echo "    Already running."
  fi
else
  echo "    Skip — run ./scripts/setup-qwen3-asr-sidecar.sh first"
  echo "    Then: uv pip install --python .venv-qwen3-asr/bin/python 'mlx-qwen3-asr[serve]'"
fi

echo ""
echo "==> [2/5] Qwen3-TTS MLX HTTP server (TTS) on :${QWEN3_TTS_PORT}"
VENV_TTS="${REPO_ROOT}/.venv-qwen3-tts"
if [[ -x "${VENV_TTS}/bin/python" ]]; then
  if ! curl -sf "http://127.0.0.1:${QWEN3_TTS_PORT}/health" >/dev/null 2>&1; then
    "${VENV_TTS}/bin/python" "${REPO_ROOT}/scripts/qwen3-tts-http-sidecar.py" \
      --host 127.0.0.1 \
      --port "${QWEN3_TTS_PORT}" \
      --api-key local \
      --model mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16 \
      >/tmp/clicky-qwen3-tts-http.log 2>&1 &
    echo "    Starting (first run downloads model, see /tmp/clicky-qwen3-tts-http.log)..."
    for _ in $(seq 1 180); do
      if curl -sf "http://127.0.0.1:${QWEN3_TTS_PORT}/health" >/dev/null 2>&1; then
        echo "    Ready: http://127.0.0.1:${QWEN3_TTS_PORT}/health"
        break
      fi
      sleep 2
    done
  else
    echo "    Already running."
  fi
else
  echo "    Skip — run ./scripts/setup-qwen3-tts-sidecar.sh first"
fi

echo ""
echo "==> [3/5] pi-mono ai-server (Ollama Gemma) on :${PI_GEMINI_PORT}"
if [[ -x "${REPO_ROOT}/scripts/start-pi-gemini-proxy.sh" ]]; then
  if ! curl -sf "http://127.0.0.1:${PI_GEMINI_PORT}/health" >/dev/null 2>&1; then
    PI_GEMINI_PROXY_PORT="${PI_GEMINI_PORT}" \
      "${REPO_ROOT}/scripts/start-pi-gemini-proxy.sh" --daemon
  else
    echo "    Already running."
  fi
else
  echo "    Skip — missing scripts/start-pi-gemini-proxy.sh"
fi

echo ""
echo "==> [4/5] Cloudflare Worker (legacy TTS proxy) on :${WORKER_PORT}"
if [[ -f "${REPO_ROOT}/worker/.dev.vars" ]]; then
  if ! curl -sf "http://127.0.0.1:${WORKER_PORT}/" >/dev/null 2>&1; then
    (cd worker && npx wrangler dev --port "${WORKER_PORT}" --local-protocol http) \
      >/tmp/clicky-worker.log 2>&1 &
    echo "    Starting wrangler dev (see /tmp/clicky-worker.log)..."
    sleep 3
  else
    echo "    Already running."
  fi
else
  echo "    Skip — copy worker/.dev.vars.example → worker/.dev.vars and add API keys"
  echo "    Without Worker: local Qwen3-TTS still works"
fi

echo ""
echo "==> [5/5] Opening Xcode"
open "${REPO_ROOT}/leanring-buddy.xcodeproj"

echo ""
echo "In Xcode:"
echo "  1. leanring-buddy → Signing & Capabilities → select your Team"
echo "  2. Scheme: leanring-buddy"
echo "  3. Press Cmd+R to run"
echo ""
echo "Press Ctrl+C here to stop background services when done."
wait
