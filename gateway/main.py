"""WisprClaw Transcription Gateway.

A FastAPI server that accepts audio uploads and returns transcribed text.
Run with: python main.py
"""

from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse
import uvicorn

app = FastAPI(title="WisprClaw Gateway")


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    """Accept an audio file and return transcribed text.

    Currently returns a stub response with byte count.
    Replace the stub below with Whisper inference to enable real STT.
    """
    data = await audio.read()

    # ── Plug in Whisper here ──────────────────────────────────────────
    # import whisper
    # model = whisper.load_model("base")
    # result = model.transcribe(audio_path)
    # text = result["text"]
    # ──────────────────────────────────────────────────────────────────

    text = f"[stub] Audio received, {len(data)} bytes"

    return JSONResponse(content={"text": text})


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000)
