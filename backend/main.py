"""County Narrator — TTS for auto-attendant & voicemail greetings.

FastAPI backend serving a static frontend. The model loads in a background
worker thread, so /api/health responds immediately after container start
(reporting model_loaded: false while weights download/load).
"""
import logging
import os
from pathlib import Path

from fastapi import FastAPI, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .engine import TTSEngine
from .jobs import JobError, JobManager
from .voices import VoiceError, VoiceStore

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("narrator")

APP_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("DATA_DIR", APP_DIR / "data"))
FRONTEND_DIR = APP_DIR / "frontend"
VERSION = (APP_DIR / "VERSION").read_text().strip() if (APP_DIR / "VERSION").exists() else "dev"

app = FastAPI(title="County Narrator", version=VERSION)

engine = TTSEngine()
voices = VoiceStore(DATA_DIR / "voices")
jobs = JobManager(engine, DATA_DIR / "outputs")


@app.on_event("startup")
def _startup():
    jobs.prune_history()
    jobs.start()  # worker thread loads the model, then serves the queue


# -- meta ---------------------------------------------------------------------

@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "version": VERSION,
        "device": engine.device,
        "model": "chatterbox-turbo",
        "model_loaded": engine.is_loaded,
        "model_error": engine.load_error,
    }


# -- voices ---------------------------------------------------------------------

@app.get("/api/voices")
def list_voices():
    return voices.list()


@app.post("/api/voices")
async def add_voice(name: str = Form(...), file: UploadFile = Form(...)):
    data = await file.read()
    try:
        return voices.add(name, file.filename or "", data)
    except VoiceError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/voices/{voice_id}/audio")
def voice_audio(voice_id: str):
    path = voices.path_for(voice_id)
    if not path or not path.exists():
        raise HTTPException(status_code=404, detail="Voice not found")
    return FileResponse(path, filename=path.name)


@app.delete("/api/voices/{voice_id}")
def delete_voice(voice_id: str):
    if not voices.delete(voice_id):
        raise HTTPException(status_code=404, detail="Voice not found")
    return {"status": "deleted"}


# -- jobs ----------------------------------------------------------------------

@app.post("/api/jobs")
def create_job(body: dict):
    text = str(body.get("text", ""))
    voice_id = body.get("voice_id") or None
    try:
        temperature = float(body.get("temperature", 0.8))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="temperature must be a number")

    voice_name = "Built-in voice"
    voice_path = None
    if voice_id:
        voice = voices.get(voice_id)
        if not voice:
            raise HTTPException(status_code=404, detail="Selected voice no longer exists")
        voice_name = voice["name"]
        voice_path = str(voices.path_for(voice_id))

    try:
        return jobs.submit(text, voice_id, voice_name, voice_path, temperature=temperature)
    except JobError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/jobs/{job_id}")
def job_status(job_id: str):
    status = jobs.status(job_id)
    if not status:
        raise HTTPException(status_code=404, detail="Job not found")
    return status


@app.get("/api/jobs/{job_id}/audio")
def job_audio(job_id: str, format: str = "pbx"):
    if format not in ("pbx", "studio"):
        raise HTTPException(status_code=400, detail="format must be 'pbx' or 'studio'")
    path = jobs.audio_path(job_id, format)
    if not path:
        raise HTTPException(status_code=404, detail="Audio not found (job may have failed or been pruned)")
    label = "8khz" if format == "pbx" else "3c-host"
    return FileResponse(path, media_type="audio/wav",
                        filename=f"county-narrator-{job_id}-{label}.wav")


# -- history ---------------------------------------------------------------------

@app.get("/api/history")
def history():
    return jobs.history()


@app.delete("/api/history/{job_id}")
def delete_history(job_id: str):
    if not jobs.delete_history(job_id):
        raise HTTPException(status_code=404, detail="Not found")
    return {"status": "deleted"}


# -- frontend (mounted last so /api/* wins) ---------------------------------------

app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
