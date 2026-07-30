#!/usr/bin/env python3
"""Single-thread Qwen3-ASR HTTP server (OpenAI-compatible).

The upstream ``mlx-qwen3-asr serve`` offloads inference with ``asyncio.to_thread``,
which breaks MLX GPU streams ("There is no Stream(gpu, 1) in current thread").
This sidecar loads the model once and runs every request on the same thread.

Endpoints:
  GET  /health
  GET  /v1/models
  POST /v1/audio/transcriptions   (OpenAI-compatible, Bearer auth)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional


def log(message: str) -> None:
    print(f"[qwen3-http] {message}", file=sys.stderr, flush=True)


def parse_multipart_form(body: bytes, content_type: str) -> dict[str, bytes | str]:
    boundary_match = re.search(r"boundary=([^;\s]+)", content_type)
    if not boundary_match:
        raise ValueError("Missing multipart boundary")

    boundary = boundary_match.group(1).strip('"')
    delimiter = f"--{boundary}".encode()
    fields: dict[str, bytes | str] = {}

    for part in body.split(delimiter)[1:-1]:
        chunk = part
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        if chunk.endswith(b"\r\n"):
            chunk = chunk[:-2]

        header_end = chunk.find(b"\r\n\r\n")
        if header_end == -1:
            continue

        headers = chunk[:header_end].decode("utf-8", errors="replace")
        data = chunk[header_end + 4 :]

        name_match = re.search(r'name="([^"]+)"', headers)
        if not name_match:
            continue

        field_name = name_match.group(1)
        if 'filename="' in headers:
            fields[field_name] = data
        else:
            fields[field_name] = data.decode("utf-8", errors="replace").strip()

    return fields


def openai_error(message: str, *, status_code: int = 500) -> dict:
    if status_code == 401:
        error_type = "authentication_error"
    elif status_code == 403:
        error_type = "permission_error"
    else:
        error_type = "server_error" if status_code >= 500 else "invalid_request_error"

    return {
        "error": {
            "message": message,
            "type": error_type,
            "param": None,
            "code": None,
        }
    }


def clean_transcript(raw_text: str) -> str:
    if "<asr_text>" in raw_text:
        return raw_text.split("<asr_text>", 1)[1].strip()
    if raw_text.lower().startswith("language ") and ">" in raw_text:
        return raw_text.split(">", 1)[1].strip()
    return raw_text.strip()


def create_handler(*, api_key: str, model_name: str, session):
    class Qwen3HTTPHandler(BaseHTTPRequestHandler):
        server_version = "Qwen3ASRHTTPSidecar/1.0"

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
                        "engine": "qwen3-asr-mlx-single-thread",
                        "model": model_name,
                    },
                )
                return

            if self.path == "/v1/models":
                try:
                    self._require_auth()
                except PermissionError:
                    return
                self._send_json(
                    200,
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": model_name,
                                "object": "model",
                                "created": 0,
                                "owned_by": "qwen3-asr-http-sidecar",
                            }
                        ],
                    },
                )
                return

            self.send_error(404)

        def do_POST(self) -> None:
            if self.path != "/v1/audio/transcriptions":
                self.send_error(404)
                return

            try:
                self._require_auth()
            except PermissionError:
                return

            content_length = int(self.headers.get("Content-Length", "0"))
            content_type = self.headers.get("Content-Type", "")
            body = self.rfile.read(content_length)

            try:
                fields = parse_multipart_form(body, content_type)
            except ValueError as exc:
                self._send_json(400, openai_error(str(exc), status_code=400))
                return

            file_data = fields.get("file")
            if not isinstance(file_data, (bytes, bytearray)) or not file_data:
                self._send_json(400, openai_error("Missing multipart field: file", status_code=400))
                return

            language = fields.get("language")
            prompt = fields.get("prompt")
            language_str = language if isinstance(language, str) and language else None
            prompt_str = prompt if isinstance(prompt, str) else ""

            temp_path: Optional[str] = None
            try:
                with tempfile.NamedTemporaryFile(
                    suffix=".wav", delete=False, prefix="clicky_qwen3_"
                ) as temp_file:
                    temp_file.write(file_data)
                    temp_path = temp_file.name

                result = session.transcribe(
                    temp_path,
                    language=language_str,
                    context=prompt_str,
                    return_chunks=True,
                )
                text = clean_transcript(result.text)
                self._send_json(200, {"text": text})
            except Exception as exc:
                log(f"transcription failed: {exc}")
                self._send_json(500, openai_error(str(exc), status_code=500))
            finally:
                if temp_path:
                    Path(temp_path).unlink(missing_ok=True)

    return Qwen3HTTPHandler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--api-key", default="local")
    parser.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    args = parser.parse_args()

    log(f"Loading {args.model} on main thread...")
    from mlx_qwen3_asr import Session

    session = Session(model=args.model)
    log("Model ready.")

    handler = create_handler(api_key=args.api_key, model_name=args.model, session=session)
    httpd = HTTPServer((args.host, args.port), handler)
    log(f"Listening on http://{args.host}:{args.port}")
    log("OpenAI endpoint: POST /v1/audio/transcriptions")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        log("Stopped.")


if __name__ == "__main__":
    main()
