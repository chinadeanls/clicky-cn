#!/usr/bin/env bash
# Start Qwen3-ASR MLX JSONL bridge for Clicky / Swift integration.
#
# Protocol: newline-delimited JSON on stdin/stdout.
# See vendor/qwen3-asr-mlx-runtime/docs/protocol.md
#
# Usage:
#   ./scripts/start-qwen3-asr-jsonl.sh                    # 0.6B default
#   ./scripts/start-qwen3-asr-jsonl.sh Qwen/Qwen3-ASR-1.7B  # 1.7B accuracy mode

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="${REPO_ROOT}/vendor/qwen3-asr-mlx-runtime"
BRIDGE="${RUNTIME_DIR}/scripts/qwen3-asr-mlx-bridge"
MODEL="${1:-Qwen/Qwen3-ASR-0.6B}"

if [[ ! -x "${BRIDGE}" ]]; then
  echo "Missing runtime. Run: ./scripts/setup-qwen3-asr-sidecar.sh"
  exit 1
fi

echo "==> Starting Qwen3-ASR JSONL bridge (MLX), model=${MODEL}" >&2
echo "    Send JSON lines to stdin, read responses from stdout." >&2
echo "" >&2

exec "${BRIDGE}" "${MODEL}"
