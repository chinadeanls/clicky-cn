#!/usr/bin/env bash
# One-time setup for Qwen3-ASR MLX sidecar (SSE + JSONL).
#
# Requirements: macOS Apple Silicon, uv, network for first model download.
#
# Usage:
#   ./scripts/setup-qwen3-asr-sidecar.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Creating Python 3.12 venv"
uv venv .venv-qwen3-asr --python 3.12

echo "==> Installing TextStream deps (includes mlx-qwen3-asr + sounddevice)"
uv pip install --python .venv-qwen3-asr/bin/python textstream-asr silero-vad-lite

if [[ ! -d vendor/qwen3-asr-mlx-runtime ]]; then
  echo "==> Cloning JSONL bridge runtime"
  git clone --depth 1 https://github.com/drguptavivek/qwen3-asr-mlx-runtime.git vendor/qwen3-asr-mlx-runtime
fi

echo ""
echo "==> Setup complete. Next steps:"
echo ""
echo "  # HTTP sidecar for Clicky App (OpenAI-compatible, single-thread MLX):"
echo "  ./scripts/start-qwen3-asr-http.sh"
echo "  # Health: http://127.0.0.1:8765/health"
echo ""
echo "  # SSE live sidecar (mic → http://127.0.0.1:17890/stream):"
echo "  ./scripts/start-qwen3-asr-sse.sh"
echo "  # Open http://127.0.0.1:17890/ in browser — grant mic to Terminal/Cursor if prompted"
echo ""
echo "  # JSONL bridge (app sends audio chunks via stdin):"
echo "  ./scripts/start-qwen3-asr-jsonl.sh"
echo ""
echo "  # Smoke tests:"
echo "  ./scripts/test-qwen3-asr-sse.sh"
echo "  ./scripts/test-qwen3-asr-jsonl.sh"
