#!/usr/bin/env bash
# Verify SSE sidecar is responding (does not require speech).
set -euo pipefail

PORT="${QWEN3_ASR_PORT:-17890}"
BASE="http://localhost:${PORT}"

echo "==> Checking ${BASE}/engine"
curl -sf "${BASE}/engine" | python3 -m json.tool

echo ""
echo "==> SSE stream (speak into mic — Ctrl+C to stop)"
echo "    Listening on ${BASE}/stream"
echo ""

curl -sfN "${BASE}/stream" | while IFS= read -r line; do
  if [[ "${line}" == data:* ]]; then
    echo "${line#data: }" | python3 -m json.tool 2>/dev/null || echo "${line#data: }"
  fi
done
