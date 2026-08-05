"""OpenAI-compatible speech-to-text server backed by Moonshine v2.

Open WebUI speaks the OpenAI audio API; Moonshine ships no server of its own,
so this is the thin adapter between them.

Design notes:
  - The model is loaded once at startup, never per request. /healthz stays 503
    until that finishes so Kubernetes does not route traffic to a cold pod.
  - Moonshine's Transcriber is not documented as thread-safe, so every
    inference is serialised behind an asyncio lock. Scale with replicas, not
    threads (the deployment runs a single uvicorn worker).
  - Anything the OpenAI spec allows but Moonshine cannot honour (temperature,
    prompt, timestamp granularities) is accepted and ignored rather than
    rejected -- clients send these routinely and erroring would break them.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("moonshine-stt")

MODEL_NAME = os.environ.get("MOONSHINE_MODEL", "small-streaming")
LANGUAGE = os.environ.get("MOONSHINE_LANGUAGE", "en")
TARGET_SAMPLE_RATE = 16_000
# Guard against a huge upload exhausting pod memory during transcode.
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", 100 * 1024 * 1024))

app = FastAPI(title="Moonshine STT", version="1.0.0")

_transcriber = None
_model_ready = False
_model_error: Optional[str] = None
_infer_lock = asyncio.Lock()


def _load_model() -> None:
    """Load Moonshine once. Called from the startup hook."""
    global _transcriber, _model_ready, _model_error
    try:
        from moonshine_voice import (
            ModelArch,
            Transcriber,
            get_model_for_language,
            string_to_model_arch,
        )

        started = time.time()
        try:
            arch = string_to_model_arch(MODEL_NAME)
        except Exception:
            log.warning("unknown MOONSHINE_MODEL %r, falling back to small-streaming", MODEL_NAME)
            arch = ModelArch.SMALL_STREAMING

        # Returns a local path; weights are baked into the image at build time
        # so this must not reach the network at runtime.
        model_path, resolved_arch = get_model_for_language(LANGUAGE, arch)
        transcriber = Transcriber(model_path=model_path, model_arch=resolved_arch)
        transcriber.start()

        _transcriber = transcriber
        _model_ready = True
        log.info(
            "model ready name=%s lang=%s load_seconds=%.2f",
            MODEL_NAME, LANGUAGE, time.time() - started,
        )
    except Exception as exc:  # noqa: BLE001 - surfaced via /healthz
        _model_error = str(exc)
        log.exception("model failed to load")


@app.on_event("startup")
async def startup() -> None:
    # Load off the event loop so the health endpoint can answer while we wait.
    await asyncio.get_running_loop().run_in_executor(None, _load_model)


@app.on_event("shutdown")
async def shutdown() -> None:
    if _transcriber is not None:
        try:
            _transcriber.stop()
            _transcriber.close()
        except Exception:  # noqa: BLE001 - best effort on the way down
            log.warning("transcriber shutdown was not clean", exc_info=True)


@app.get("/healthz")
async def healthz():
    """200 only once the model is loaded and usable."""
    if _model_ready:
        return {"status": "ok", "model": MODEL_NAME, "language": LANGUAGE}
    return JSONResponse(
        status_code=503,
        content={"status": "loading" if _model_error is None else "error",
                 "error": _model_error},
    )


@app.get("/v1/models")
async def list_models():
    """Some OpenAI clients probe this before transcribing."""
    return {"object": "list", "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "moonshine"}]}


def _decode_to_pcm16k(raw: bytes, suffix: str) -> tuple[list[float], int]:
    """Transcode arbitrary container/codec input to 16 kHz mono float samples.

    Open WebUI's mic records webm/ogg, and users upload mp3/m4a, so everything
    goes through ffmpeg rather than trusting the input to already be wav.
    """
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / f"in{suffix or '.bin'}"
        dst = Path(tmp) / "out.wav"
        src.write_bytes(raw)

        proc = subprocess.run(
            [
                "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                "-i", str(src),
                "-ar", str(TARGET_SAMPLE_RATE), "-ac", "1",
                "-c:a", "pcm_s16le", str(dst),
            ],
            capture_output=True,
        )
        if proc.returncode != 0 or not dst.exists():
            detail = proc.stderr.decode("utf-8", "replace")[:500] or "ffmpeg failed"
            raise HTTPException(status_code=400, detail=f"could not decode audio: {detail}")

        from moonshine_voice import load_wav_file

        return load_wav_file(dst)


def _run_inference(audio: list[float], sample_rate: int) -> str:
    result = _transcriber.transcribe_without_streaming(audio, sample_rate)
    # Transcript.text carries "[0.00s] " timestamp prefixes; join the line
    # texts instead so callers get clean prose.
    lines = getattr(result, "lines", None)
    if lines:
        return " ".join(line.text.strip() for line in lines if line.text).strip()
    return str(getattr(result, "text", "")).strip()


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    response_format: Optional[str] = Form("json"),
    # Accepted for OpenAI compatibility, ignored by Moonshine.
    prompt: Optional[str] = Form(None),
    temperature: Optional[str] = Form(None),
    timestamp_granularities: Optional[str] = Form(None),
):
    if not _model_ready:
        raise HTTPException(status_code=503, detail=f"model not ready: {_model_error or 'loading'}")

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="empty audio file")
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail=f"audio exceeds {MAX_UPLOAD_BYTES} bytes")

    if language and language.lower() not in (LANGUAGE, "auto", ""):
        # Honouring this would need a different model; log rather than fail.
        log.info("ignoring requested language=%r, server serves %r", language, LANGUAGE)

    suffix = Path(file.filename or "").suffix.lower()
    loop = asyncio.get_running_loop()
    audio, sample_rate = await loop.run_in_executor(None, _decode_to_pcm16k, raw, suffix)

    duration = len(audio) / sample_rate if sample_rate else 0.0
    started = time.time()
    # Serialised: Moonshine inference is not proven thread-safe.
    async with _infer_lock:
        text = await loop.run_in_executor(None, _run_inference, audio, sample_rate)
    elapsed = time.time() - started

    log.info(
        "transcribed bytes=%d audio_seconds=%.2f infer_seconds=%.2f rtf=%.3f",
        len(raw), duration, elapsed, (elapsed / duration) if duration else 0.0,
    )

    if (response_format or "json").lower() == "text":
        return PlainTextResponse(text)
    return {"text": text}


@app.get("/")
async def root():
    return {"service": "moonshine-stt", "model": MODEL_NAME, "ready": _model_ready}
