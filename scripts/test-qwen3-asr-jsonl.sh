#!/usr/bin/env bash
# Smoke test JSONL bridge with bundled sample audio.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE_WAV="${1:-/tmp/clicky-stt-test.wav}"
BRIDGE="${REPO_ROOT}/vendor/qwen3-asr-mlx-runtime/scripts/qwen3-asr-mlx-bridge"

if [[ ! -f "${SAMPLE_WAV}" ]]; then
  echo "==> Generating test WAV: ${SAMPLE_WAV}"
  say -o /tmp/clicky-stt-test.aiff "你好，这是一个语音识别测试。"
  afconvert /tmp/clicky-stt-test.aiff "${SAMPLE_WAV}" -d LEI16 -f WAVE
fi

echo "==> Transcribing ${SAMPLE_WAV} via JSONL bridge (first run downloads model)"
echo ""

printf '%s\n' \
  '{"type":"start"}' \
  "{\"type\":\"transcribe\",\"audio\":\"${SAMPLE_WAV}\",\"max_new_tokens\":0}" \
  '{"type":"stop"}' \
| "${BRIDGE}" 2>/dev/null | python3 -m json.tool
