"""Standalone Whisper transcription gateway for WisprClaw.

Run:
  python whisper_gateway.py

Required packages:
  pip install fastapi "uvicorn[standard]" python-multipart openai-whisper

Environment variables:
  WHISPER_MODEL=base        # tiny, base, small, medium, large
  WHISPER_DOWNLOAD_ROOT=~/.cache/whisper
  WHISPER_SSL_CA_FILE=/path/to/ca-bundle.pem
  WHISPER_INSECURE_DOWNLOAD=0   # set 1 only as last resort
  GATEWAY_HOST=127.0.0.1
  GATEWAY_PORT=8001
  MAX_AUDIO_MB=25
"""

from __future__ import annotations

import os
import ssl
import tempfile
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
import uvicorn


MODEL_NAME = os.getenv("WHISPER_MODEL", "base")
WHISPER_DOWNLOAD_ROOT = os.getenv("WHISPER_DOWNLOAD_ROOT")
WHISPER_SSL_CA_FILE = os.getenv("WHISPER_SSL_CA_FILE")
WHISPER_INSECURE_DOWNLOAD = os.getenv("WHISPER_INSECURE_DOWNLOAD", "0").lower() in {
    "1",
    "true",
    "yes",
}
MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_MB", "25")) * 1024 * 1024

app = FastAPI(title="WisprClaw Whisper Gateway")
_model = None


def configure_whisper_download_tls() -> None:
    """Configure urllib TLS trust used by Whisper model downloads."""
    if WHISPER_INSECURE_DOWNLOAD:
        insecure_context = ssl._create_unverified_context()
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=insecure_context)
        )
        urllib.request.install_opener(opener)
        return

    ca_file = WHISPER_SSL_CA_FILE or os.getenv("SSL_CERT_FILE")
    if not ca_file:
        try:
            import certifi

            ca_file = certifi.where()
        except Exception:
            ca_file = None

    if ca_file:
        os.environ.setdefault("SSL_CERT_FILE", ca_file)
        context = ssl.create_default_context(cafile=ca_file)
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context)
        )
        urllib.request.install_opener(opener)


def get_model() -> Any:
    """Load Whisper once per process and reuse across requests."""
    global _model
    if _model is not None:
        return _model

    try:
        import whisper  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "openai-whisper is not installed. "
            "Install with: pip install openai-whisper"
        ) from exc

    configure_whisper_download_tls()

    load_kwargs: dict[str, Any] = {}
    if WHISPER_DOWNLOAD_ROOT:
        load_kwargs["download_root"] = os.path.expanduser(WHISPER_DOWNLOAD_ROOT)

    try:
        _model = whisper.load_model(MODEL_NAME, **load_kwargs)
    except Exception as exc:
        message = str(exc)
        if "CERTIFICATE_VERIFY_FAILED" in message or "certificate verify failed" in message:
            raise RuntimeError(
                "Whisper model download failed TLS verification. "
                "Set WHISPER_SSL_CA_FILE to your trusted CA bundle, "
                "or set WHISPER_INSECURE_DOWNLOAD=1 as a last resort."
            ) from exc
        raise

    return _model


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)) -> dict[str, str]:
    """Accept multipart audio file and return transcribed text."""
    raw_audio = await audio.read()
    if not raw_audio:
        raise HTTPException(status_code=400, detail="Empty audio upload")
    if len(raw_audio) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Audio too large. Max allowed is {MAX_AUDIO_BYTES} bytes",
        )

    suffix = Path(audio.filename or "recording.wav").suffix or ".wav"
    temp_path = ""

    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
            temp_file.write(raw_audio)
            temp_path = temp_file.name

        model = get_model()
        result = model.transcribe(temp_path, fp16=False)
        text = (result.get("text") or "").strip()
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] transcript: {text}",
            flush=True,
        )
        return {"text": text}
    except RuntimeError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {exc}") from exc
    finally:
        if temp_path:
            try:
                os.remove(temp_path)
            except OSError:
                pass
        await audio.close()


if __name__ == "__main__":
    host = os.getenv("GATEWAY_HOST", "127.0.0.1")
    port = int(os.getenv("GATEWAY_PORT", "8001"))
    uvicorn.run(app, host=host, port=port)
