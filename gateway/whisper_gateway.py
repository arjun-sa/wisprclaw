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


def _is_truthy(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _load_dotenv() -> None:
    """Load .env values into process env if not already exported.

    Search order:
    1) current working directory
    2) gateway directory
    3) project root (parent of gateway directory)
    """
    search_paths = [
        Path.cwd() / ".env",
        Path(__file__).resolve().parent / ".env",
        Path(__file__).resolve().parent.parent / ".env",
    ]
    seen: set[Path] = set()

    for env_path in search_paths:
        resolved = env_path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)

        if not env_path.exists():
            continue

        try:
            lines = env_path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue

        for raw_line in lines:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue

            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()

            if key.startswith("export "):
                key = key[len("export ") :].strip()

            if not key:
                continue

            if value.startswith('"') and value.endswith('"') and len(value) >= 2:
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'") and len(value) >= 2:
                value = value[1:-1]
            else:
                value = value.split(" #", 1)[0].strip()

            os.environ.setdefault(key, value)

        # Stop at the first .env file found in the search order.
        break


_load_dotenv()

MODEL_NAME = os.getenv("WHISPER_MODEL", "base")
WHISPER_DOWNLOAD_ROOT = os.getenv("WHISPER_DOWNLOAD_ROOT")
WHISPER_SSL_CA_FILE = os.getenv("WHISPER_SSL_CA_FILE")
WHISPER_INSECURE_DOWNLOAD = _is_truthy(os.getenv("WHISPER_INSECURE_DOWNLOAD", "0"))
LLMLINGUA_MODEL = os.getenv(
    "LLMLINGUA_MODEL", "microsoft/llmlingua-2-xlm-roberta-large-meetingbank"
)
LLMLINGUA_ENABLED = _is_truthy(os.getenv("LLMLINGUA_ENABLED", "1"), default=True)
LLMLINGUA_DEVICE = os.getenv("LLMLINGUA_DEVICE", "auto").strip().lower()
LLMLINGUA_RATE = float(os.getenv("LLMLINGUA_RATE", "0.6"))
LLMLINGUA_USE_V2 = _is_truthy(os.getenv("LLMLINGUA_USE_V2", "1"), default=True)
MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_MB", "25")) * 1024 * 1024

app = FastAPI(title="WisprClaw Whisper Gateway")
_model = None
_compressor = None


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
    if ca_file and not Path(ca_file).expanduser().is_file():
        ca_file = None
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


def get_compressor() -> Any:
    """Load LLMLingua once per process and reuse across requests."""
    global _compressor
    if _compressor is not None:
        return _compressor

    try:
        from llmlingua import PromptCompressor
    except ImportError as exc:
        raise RuntimeError(
            "llmlingua is not installed. "
            "Install with: pip install llmlingua accelerate"
        ) from exc

    init_kwargs: dict[str, Any] = {"model_name": LLMLINGUA_MODEL}

    device_map = LLMLINGUA_DEVICE
    if device_map == "auto":
        try:
            import torch

            if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
                device_map = "mps"
            elif torch.cuda.is_available():
                device_map = "cuda"
            else:
                device_map = "cpu"
        except Exception:
            device_map = "cpu"
    init_kwargs["device_map"] = device_map

    if LLMLINGUA_USE_V2:
        init_kwargs["use_llmlingua2"] = True

    _compressor = PromptCompressor(**init_kwargs)
    return _compressor


def extract_compressed_text(compression_result: Any, original_text: str = "") -> str:
    """Normalize LLMLingua output across versions."""
    if isinstance(compression_result, str):
        return compression_result.strip()

    if isinstance(compression_result, dict):
        for key in ("compressed_prompt", "compressed_text", "prompt", "text"):
            value = compression_result.get(key)
            if isinstance(value, str):
                return value.strip()

    if original_text:
        return original_text
    raise RuntimeError("LLMLingua returned an unexpected compression result")


def compress_transcript(text: str) -> str:
    compressor = get_compressor()
    clean_text = text.strip()
    if not clean_text:
        return clean_text

    context = [clean_text]

    try:
        if LLMLINGUA_USE_V2 and hasattr(compressor, "compress_prompt_llmlingua2"):
            result = compressor.compress_prompt_llmlingua2(context, rate=LLMLINGUA_RATE)
        else:
            result = compressor.compress_prompt(context, rate=LLMLINGUA_RATE)
    except TypeError:
        result = compressor.compress_prompt(context, rate=LLMLINGUA_RATE)

    return extract_compressed_text(result, original_text=clean_text)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    compress: str | None = None,
) -> dict[str, str]:
    """Accept multipart audio file and return transcribed text.

    The optional ``compress`` query parameter overrides the server-wide
    ``LLMLINGUA_ENABLED`` setting for this single request.  Accepted values
    are ``1``/``true``/``yes``/``on`` to enable and ``0``/``false``/``no``/``off``
    to disable.
    """
    raw_audio = await audio.read()
    if not raw_audio:
        raise HTTPException(status_code=400, detail="Empty audio upload")
    if len(raw_audio) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"Audio too large. Max allowed is {MAX_AUDIO_BYTES} bytes",
        )

    # Determine whether to compress: per-request param overrides global default
    if compress is not None:
        should_compress = _is_truthy(compress)
    else:
        should_compress = LLMLINGUA_ENABLED

    suffix = Path(audio.filename or "recording.wav").suffix or ".wav"
    temp_path = ""

    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
            temp_file.write(raw_audio)
            temp_path = temp_file.name

        model = get_model()
        result = model.transcribe(temp_path, fp16=False)
        original_text = (result.get("text") or "").strip()
        compressed_text = (
            compress_transcript(original_text) if should_compress else original_text
        )
        timestamp = datetime.now().isoformat(timespec="seconds")
        print(
            f"[{timestamp}] transcript_original: {original_text}",
            flush=True,
        )
        print(
            f"[{timestamp}] transcript_compressed: {compressed_text}",
            flush=True,
        )
        return {"text": compressed_text}
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
