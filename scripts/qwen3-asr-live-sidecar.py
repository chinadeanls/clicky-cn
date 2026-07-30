#!/usr/bin/env python3
"""Qwen3-ASR live sidecar with MLX on the main thread (fixes TextStream GPU stream bug).

SSE: GET http://127.0.0.1:{port}/stream
Health: GET http://127.0.0.1:{port}/health
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16000

audio_queue: queue.Queue[np.ndarray] = queue.Queue(maxsize=400)
sse_subscribers: list[queue.Queue[bytes]] = []
sse_lock = threading.Lock()
latest_event = {"type": "status", "content": "starting"}
latest_lock = threading.Lock()
running = True
_vad_instance = None
_vad_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[qwen3-sidecar] {message}", file=sys.stderr, flush=True)


def broadcast(event: dict) -> None:
    payload = f"data: {json.dumps(event, ensure_ascii=False)}\n\n".encode()
    with latest_lock:
        global latest_event
        latest_event = event
    with sse_lock:
        dead: list[queue.Queue[bytes]] = []
        for subscriber_queue in sse_subscribers:
            try:
                subscriber_queue.put_nowait(payload)
            except queue.Full:
                try:
                    subscriber_queue.get_nowait()
                    subscriber_queue.put_nowait(payload)
                except Exception:
                    dead.append(subscriber_queue)
            except Exception:
                dead.append(subscriber_queue)
        for dead_queue in dead:
            sse_subscribers.remove(dead_queue)


def drain_audio_buffer() -> np.ndarray | None:
    chunks: list[np.ndarray] = []
    while True:
        try:
            chunks.append(audio_queue.get_nowait())
        except queue.Empty:
            break
    if not chunks:
        return None
    return np.concatenate(chunks)


def get_vad():
    global _vad_instance
    with _vad_lock:
        if _vad_instance is None:
            from silero_vad_lite import SileroVAD

            _vad_instance = SileroVAD(SAMPLE_RATE)
        return _vad_instance


def contains_speech(audio_chunk: np.ndarray, threshold: float) -> bool:
    vad = get_vad()
    frame_size = 512 if SAMPLE_RATE == 16000 else 256
    probabilities = []
    for start_index in range(0, len(audio_chunk) - frame_size + 1, frame_size):
        frame = audio_chunk[start_index : start_index + frame_size]
        probabilities.append(vad.process(memoryview(frame.astype(np.float32).data)))
    if not probabilities:
        return True
    return max(probabilities) >= threshold


class SidecarHandler(BaseHTTPRequestHandler):
    server_version = "Qwen3ASRSidecar/1.1"

    def log_message(self, format: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            subscriber_queue: queue.Queue[bytes] = queue.Queue(maxsize=32)
            with sse_lock:
                sse_subscribers.append(subscriber_queue)
            with latest_lock:
                initial_payload = f"data: {json.dumps(latest_event, ensure_ascii=False)}\n\n".encode()
            try:
                self.wfile.write(initial_payload)
                self.wfile.flush()
                while running:
                    try:
                        payload = subscriber_queue.get(timeout=15.0)
                        self.wfile.write(payload)
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with sse_lock:
                    if subscriber_queue in sse_subscribers:
                        sse_subscribers.remove(subscriber_queue)
            return

        if self.path.startswith("/health") or self.path.startswith("/engine"):
            body = json.dumps({"status": "ok", "engine": "qwen3-asr-mlx", "profile": "latency"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/":
            html = (
                "<!doctype html><html><body style='font:16px sans-serif;padding:24px'>"
                "<h3>Qwen3-ASR MLX Sidecar</h3>"
                "<p>Speak naturally — text finalizes ~1s after you stop talking.</p>"
                "<pre id='out' style='background:#111;color:#0f0;padding:16px;min-height:120px'></pre>"
                "<script>"
                "const out=document.getElementById('out');"
                "const src=new EventSource('/stream');"
                "src.onmessage=(e)=>{"
                " const d=JSON.parse(e.data);"
                " if(d.type==='stream'){out.textContent=(d.finalized||'')+(d.draft?(' '+d.draft):'');}"
                " else if(d.content){out.textContent=d.content;}"
                "};"
                "</script></body></html>"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return

        self.send_response(404)
        self.end_headers()


def start_http_server(host: str, port: int) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), SidecarHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd


def run_transcription_loop(
    model_name: str,
    *,
    interval_seconds: float,
    chunk_size_sec: float,
    finalization_mode: str,
    vad_threshold: float,
    min_audio_seconds: float,
    silence_flush_seconds: float,
) -> None:
    from mlx_qwen3_asr import Session

    log(
        f"Loading {model_name} (interval={interval_seconds}s, chunk={chunk_size_sec}s, "
        f"mode={finalization_mode}, silence_flush={silence_flush_seconds}s)..."
    )
    session = Session(model=model_name)

    def make_stream_state():
        return session.init_streaming(
            chunk_size_sec=chunk_size_sec,
            max_context_sec=20.0,
            finalization_mode=finalization_mode,
            sample_rate=SAMPLE_RATE,
            language=None,
            unfixed_chunk_num=1,
            unfixed_token_num=2,
            endpointing_mode="energy",
        )

    stream_state = make_stream_state()
    log("Model ready. Microphone active.")
    broadcast({"type": "status", "content": "Listening..."})

    finalized_text = ""
    has_pending_speech = False
    silence_interval_count = 0
    silence_flush_intervals = max(1, int(round(silence_flush_seconds / interval_seconds)))

    def publish_transcript(*, force_finalize: bool = False) -> None:
        nonlocal finalized_text, stream_state

        stable_text = stream_state.stable_text.strip()
        full_text = stream_state.text.strip()
        draft_text = (
            full_text[len(stable_text) :].strip()
            if len(full_text) > len(stable_text)
            else ""
        )

        if force_finalize:
            display_text = full_text or stable_text
            finalized_text = display_text
            draft_text = ""
        elif stable_text:
            finalized_text = stable_text

        broadcast(
            {
                "type": "stream",
                "finalized": finalized_text,
                "draft": draft_text if not force_finalize else "",
            }
        )
        if finalized_text or draft_text:
            suffix = " [final]" if force_finalize else ""
            log(f"… {finalized_text} {draft_text}{suffix}".strip())

    def flush_on_silence() -> None:
        nonlocal stream_state, has_pending_speech, silence_interval_count, finalized_text

        if not has_pending_speech:
            return

        infer_start = time.monotonic()
        stream_state = session.finish_streaming(stream_state)
        infer_ms = (time.monotonic() - infer_start) * 1000
        publish_transcript(force_finalize=True)
        log(f"Flushed after silence ({infer_ms:.0f}ms)")

        stream_state = make_stream_state()
        has_pending_speech = False
        silence_interval_count = 0
        finalized_text = ""

    while running:
        loop_start = time.monotonic()
        audio_chunk = drain_audio_buffer()
        heard_speech = (
            audio_chunk is not None
            and len(audio_chunk) >= int(SAMPLE_RATE * min_audio_seconds)
            and contains_speech(audio_chunk, threshold=vad_threshold)
        )

        if heard_speech:
            silence_interval_count = 0
            has_pending_speech = True
            infer_start = time.monotonic()
            stream_state = session.feed_audio(audio_chunk, stream_state)
            infer_ms = (time.monotonic() - infer_start) * 1000
            publish_transcript(force_finalize=False)
            if infer_ms > 50:
                log(f"(infer {infer_ms:.0f}ms)")
        elif has_pending_speech:
            silence_interval_count += 1
            if silence_interval_count >= silence_flush_intervals:
                flush_on_silence()

        elapsed = time.monotonic() - loop_start
        time.sleep(max(0.05, interval_seconds - elapsed))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=17890)
    parser.add_argument(
        "--model",
        default="Qwen/Qwen3-ASR-0.6B",
        help="Use Qwen/Qwen3-ASR-1.7B for higher accuracy (slower)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=0.6,
        help="Seconds between inference passes (default: 0.6)",
    )
    parser.add_argument(
        "--chunk-sec",
        type=float,
        default=1.0,
        help="Streaming chunk size in seconds (default: 1.0)",
    )
    parser.add_argument(
        "--finalization-mode",
        choices=["latency", "accuracy"],
        default="latency",
        help="latency = faster updates, accuracy = stabler text",
    )
    parser.add_argument("--vad-threshold", type=float, default=0.3)
    parser.add_argument(
        "--min-audio-sec",
        type=float,
        default=0.4,
        help="Minimum buffered audio before running inference",
    )
    parser.add_argument(
        "--silence-flush-sec",
        type=float,
        default=1.2,
        help="After this many seconds of silence, finalize the utterance",
    )
    args = parser.parse_args()

    def audio_callback(indata, frames, time_info, status) -> None:
        try:
            audio_queue.put_nowait(indata[:, 0].copy())
        except queue.Full:
            pass

    httpd = start_http_server(args.host, args.port)
    log(f"SSE server: http://{args.host}:{args.port}/stream")

    microphone_stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        callback=audio_callback,
        blocksize=int(SAMPLE_RATE * 0.05),
    )
    microphone_stream.start()

    try:
        run_transcription_loop(
            args.model,
            interval_seconds=args.interval,
            chunk_size_sec=args.chunk_sec,
            finalization_mode=args.finalization_mode,
            vad_threshold=args.vad_threshold,
            min_audio_seconds=args.min_audio_sec,
            silence_flush_seconds=args.silence_flush_sec,
        )
    except KeyboardInterrupt:
        pass
    finally:
        global running
        running = False
        microphone_stream.stop()
        microphone_stream.close()
        httpd.shutdown()
        log("Stopped.")


if __name__ == "__main__":
    main()
