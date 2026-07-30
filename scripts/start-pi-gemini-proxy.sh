#!/usr/bin/env bash
# Start pi-mono ai-server for Clicky (routes to Ollama Gemma via ~/.pi/agent/models.json).
#
# Usage:
#   ./scripts/start-pi-gemini-proxy.sh          # foreground
#   ./scripts/start-pi-gemini-proxy.sh --daemon # background (recommended before Xcode)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PI_MONO_ROOT="${PI_MONO_ROOT:-/Users/dean/Projects/pi-mono}"
AI_SERVER_DIR="${PI_MONO_ROOT}/packages/ai-server"
PORT="${PI_GEMINI_PROXY_PORT:-4141}"
PROVIDER="${PI_AI_DEFAULT_PROVIDER:-ollama}"
MODEL="${PI_AI_DEFAULT_MODEL:-gemma4:e4b}"
LOG_FILE="${PI_AI_SERVER_LOG:-/tmp/clicky-pi-gemini.log}"
PID_FILE="${PI_AI_SERVER_PID:-/tmp/clicky-pi-ai-server.pid}"
DAEMON=false

if [[ "${1:-}" == "--daemon" ]]; then
  DAEMON=true
fi

health_url="http://127.0.0.1:${PORT}/health"

if curl -sf "${health_url}" >/dev/null 2>&1; then
  echo "pi-ai-server already running: ${health_url}"
  exit 0
fi

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    echo "pi-ai-server pid ${old_pid} still starting; log: ${LOG_FILE}" >&2
    exit 1
  fi
  rm -f "${PID_FILE}"
fi

if [[ ! -d "${PI_MONO_ROOT}/packages/ai" ]]; then
  echo "Missing pi-mono at ${PI_MONO_ROOT}. Set PI_MONO_ROOT to your clone." >&2
  exit 1
fi

if [[ ! -f "${AI_SERVER_DIR}/dist/main.js" ]]; then
  echo "==> Building pi-mono ai-server (first run)..."
  npm install --prefix "${PI_MONO_ROOT}" >/dev/null 2>&1 || npm install --prefix "${PI_MONO_ROOT}"
  npm run build --prefix "${PI_MONO_ROOT}/packages/ai"
  npm run build --prefix "${AI_SERVER_DIR}"
fi

export PI_AI_SERVER_HOST="${PI_AI_SERVER_HOST:-127.0.0.1}"
export PI_AI_SERVER_PORT="${PORT}"
export PI_AI_DEFAULT_PROVIDER="${PROVIDER}"
export PI_AI_DEFAULT_MODEL="${MODEL}"

start_server() {
  exec node "${AI_SERVER_DIR}/dist/main.js"
}

if [[ "${DAEMON}" == true ]]; then
  nohup node "${AI_SERVER_DIR}/dist/main.js" >>"${LOG_FILE}" 2>&1 &
  server_pid=$!
  echo "${server_pid}" >"${PID_FILE}"

  for _ in $(seq 1 30); do
    if curl -sf "${health_url}" >/dev/null 2>&1; then
      echo "pi-ai-server ready: ${health_url} (pid ${server_pid}, log ${LOG_FILE})"
      exit 0
    fi
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      echo "pi-ai-server exited early. See ${LOG_FILE}" >&2
      tail -20 "${LOG_FILE}" >&2 || true
      rm -f "${PID_FILE}"
      exit 1
    fi
    sleep 1
  done

  echo "pi-ai-server still starting (pid ${server_pid}). Check ${LOG_FILE}" >&2
  exit 1
fi

start_server
