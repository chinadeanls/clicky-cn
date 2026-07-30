#!/usr/bin/env python3
"""Single-thread Qwen3-TTS HTTP server for Clicky (Apple Silicon + MLX).

Loads the model once on the main thread and serves every request synchronously,
avoiding MLX GPU stream threading issues.

Endpoints:
  GET  /health
  POST /v1/audio/speech   (OpenAI-compatible subset, returns WAV)
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import numpy as np
import soundfile as sf


def log(message: str) -> None:
    print(f"[qwen3-tts] {message}", file=sys.stderr, flush=True)


def openai_error(message: str, *, status_code: int = 500) -> dict[str, Any]:
    error_type = "server_error" if status_code >= 500 else "invalid_request_error"
    if status_code == 401:
        error_type = "authentication_error"
    elif status_code == 403:
        error_type = "permission_error"

    return {
        "error": {
            "message": message,
            "type": error_type,
            "param": None,
            "code": None,
        }
    }


def synthesize_wav_bytes(
    *,
    model,
    text: str,
    speaker: str,
    language: str,
    instruct: str | None,
) -> tuple[bytes, int]:
    kwargs: dict[str, Any] = {
        "text": text,
        "speaker": speaker,
        "language": language,
    }
    if instruct:
        kwargs["instruct"] = instruct

    results = list(model.generate_custom_voice(**kwargs))
    if not results:
        raise RuntimeError("Qwen3-TTS returned no audio.")

    audio = np.array(results[0].audio).astype(np.float32)
    sample_rate = int(results[0].sample_rate)

    buffer = io.BytesIO()
    sf.write(buffer, audio, sample_rate, format="WAV")
    return buffer.getvalue(), sample_rate


def create_handler(*, api_key: str, model_name: str, model, default_speaker: str, default_language: str):
    class Qwen3TTSHTTPHandler(BaseHTTPRequestHandler):
        server_version = "Qwen3TTSHTTPSidecar/1.0"

        def log_message(self, format: str, *args) -> None:
            if args and str(args[1]).startswith("2"):
                return
            log(f"{self.address_string()} {format % args}")

        def _send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _require_auth(self) -> None:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                self._send_json(401, openai_error("Missing Authorization header", status_code=401))
                raise PermissionError
            token = auth[7:].strip()
            if token != api_key:
                self._send_json(403, openai_error("Invalid API key", status_code=403))
                raise PermissionError

        def do_GET(self) -> None:
            if self.path == "/health":
                self._send_json(
                    200,
                    {
                        "status": "ok",
                        "engine": "qwen3-tts-mlx-single-thread",
                        "model": model_name,
                    },
                )
                return

            self.send_error(404)

        def do_POST(self) -> None:
            if self.path != "/v1/audio/speech":
                self.send_error(404)
                return

            try:
                self._require_auth()
            except PermissionError:
                return

            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length)

            try:
                payload = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                self._send_json(400, openai_error("Invalid JSON body", status_code=400))
                return

            text = str(payload.get("input", "")).strip()
            if not text:
                self._send_json(400, openai_error("Missing field: input", status_code=400))
                return

            speaker = str(payload.get("voice") or default_speaker).strip()
            language = str(payload.get("language") or default_language).strip()
            instruct = payload.get("instruct")
            instruct_str = str(instruct).strip() if isinstance(instruct, str) and instruct.strip() else None

            try:
                wav_bytes, sample_rate = synthesize_wav_bytes(
                    model=model,
                    text=text,
                    speaker=speaker,
                    language=language,
                    instruct=instruct_str,
                )
            except Exception as exc:
                log(f"synthesis failed: {exc}")
                self._send_json(500, openai_error(str(exc), status_code=500))
                return

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav_bytes)))
            self.send_header("X-Sample-Rate", str(sample_rate))
            self.end_headers()
            self.wfile.write(wav_bytes)

    return Qwen3TTSHTTPHandler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--api-key", default="local")
    parser.add_argument(
        "--model",
        default="mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
    )
    parser.add_argument("--default-speaker", default="Serena")
    parser.add_argument("--default-language", default="Auto")
    args = parser.parse_args()

    log(f"Loading {args.model} on main thread...")
    from mlx_audio.tts.utils import load_model

    model = load_model(args.model)
    log("Model ready.")

    handler = create_handler(
        api_key=args.api_key,
        model_name=args.model,
        model=model,
        default_speaker=args.default_speaker,
        default_language=args.default_language,
    )
    httpd = HTTPServer((args.host, args.port), handler)
    log(f"Listening on http://{args.host}:{args.port}")
    log("OpenAI endpoint: POST /v1/audio/speech")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        log("Stopped.")


if __name__ == "__main__":
    main()
