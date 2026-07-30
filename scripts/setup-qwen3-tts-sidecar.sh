#!/usr/bin/env bash
# One-time setup for Qwen3-TTS MLX HTTP sidecar.
#
# Requirements: macOS Apple Silicon, uv, network for first model download.
#
# Usage:
#   ./scripts/setup-qwen3-tts-sidecar.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Creating Python 3.12 venv"
uv venv .venv-qwen3-tts --python 3.12

echo "==> Installing mlx-audio (TTS) + soundfile"
uv pip install --python .venv-qwen3-tts/bin/python "mlx-audio[tts]" soundfile

echo ""
echo "==> Setup complete. Next steps:"
echo ""
echo "  ./scripts/start-qwen3-tts-http.sh"
echo "  # Health: http://127.0.0.1:8766/health"
echo ""
echo "  # Smoke test (first run downloads ~1.2GB model):"
echo "  curl -sf http://127.0.0.1:8766/health"
echo "  curl -s -X POST http://127.0.0.1:8766/v1/audio/speech \\"
echo "    -H 'Authorization: Bearer local' -H 'Content-Type: application/json' \\"
echo "    -d '{\"input\":\"你好，我是 Clicky。\",\"voice\":\"Serena\",\"language\":\"Chinese\"}' \\"
echo "    --output /tmp/clicky-qwen3-tts-test.wav"
