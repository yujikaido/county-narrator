"""Job queue: one worker thread owns the GPU; requests enqueue and poll.

This replaces the old design where generation ran inside the HTTP request —
long scripts no longer hang a request with a guessed timeout, concurrent
users queue instead of colliding on the GPU, and the UI gets real per-chunk
progress.
"""
import json
import logging
import queue
import threading
import time
import uuid
from pathlib import Path

from . import audio_utils
from .chunking import split_text
from .engine import TTSEngine

log = logging.getLogger("narrator.jobs")

MAX_TEXT_CHARS = 5000
HISTORY_KEEP = 50  # completed generations kept on disk


class JobError(ValueError):
    pass


class JobManager:
    def __init__(self, engine: TTSEngine, outputs_dir: Path):
        self.engine = engine
        self.outputs = outputs_dir
        self.outputs.mkdir(parents=True, exist_ok=True)
        self._jobs: dict[str, dict] = {}
        self._order: list[str] = []  # submission order, for queue position
        self._lock = threading.Lock()
        self._queue: queue.Queue = queue.Queue()
        self._worker = threading.Thread(target=self._run_worker, daemon=True, name="tts-worker")

    def start(self):
        self._worker.start()

    # -- public API --------------------------------------------------------

    def submit(self, text: str, voice_id: str | None, voice_name: str,
               voice_path: str | None, temperature: float = 0.8) -> dict:
        text = text.strip()
        if not text:
            raise JobError("No text provided.")
        temperature = min(max(float(temperature), 0.3), 1.5)
        if len(text) > MAX_TEXT_CHARS:
            raise JobError(f"Text is {len(text)} characters; the limit is {MAX_TEXT_CHARS}.")
        chunks = split_text(text)
        if not chunks:
            raise JobError("No speakable text found.")

        job = {
            "id": uuid.uuid4().hex[:12],
            "status": "queued",  # queued | running | done | error
            "text": text,
            "voice_id": voice_id,
            "voice_name": voice_name,
            "voice_path": voice_path,
            "temperature": temperature,
            "chunks_total": len(chunks),
            "chunks_done": 0,
            "chunks": chunks,
            "error": None,
            "duration_sec": None,
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        with self._lock:
            self._jobs[job["id"]] = job
            self._order.append(job["id"])
            self._trim_finished_locked()
        self._queue.put(job["id"])
        log.info("Job %s queued: %d chunk(s), voice=%s", job["id"], len(chunks), voice_name)
        return self.status(job["id"])

    def status(self, job_id: str) -> dict | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            ahead = 0
            if job["status"] == "queued":
                for jid in self._order:
                    if jid == job_id:
                        break
                    other = self._jobs.get(jid)  # tolerate ids deleted mid-flight
                    if other and other["status"] in ("queued", "running"):
                        ahead += 1
            return {
                "id": job["id"],
                "status": job["status"],
                "chunks_total": job["chunks_total"],
                "chunks_done": job["chunks_done"],
                "error": job["error"],
                "duration_sec": job["duration_sec"],
                "voice_name": job["voice_name"],
                "queue_ahead": ahead,
                "created": job["created"],
            }

    def _trim_finished_locked(self, keep: int = 200):
        """Drop the oldest finished jobs from memory (call with lock held).

        Audio/history live on disk, so dropping a finished job only stops
        /api/jobs/{id} status polling for it — the files stay downloadable.
        """
        excess = len(self._order) - keep
        if excess <= 0:
            return
        for jid in [j for j in self._order
                    if self._jobs.get(j, {}).get("status") in ("done", "error")][:excess]:
            self._order.remove(jid)
            self._jobs.pop(jid, None)

    def audio_path(self, job_id: str, fmt: str) -> Path | None:
        path = self.outputs / f"{job_id}.{fmt}.wav"
        return path if path.exists() else None

    # -- history (persisted as sidecar json next to the wav files) ----------

    def history(self) -> list[dict]:
        items = []
        for meta_path in self.outputs.glob("*.json"):
            try:
                items.append(json.loads(meta_path.read_text(encoding="utf-8")))
            except (json.JSONDecodeError, OSError):
                continue
        items.sort(key=lambda m: m.get("created", ""), reverse=True)
        return items

    def delete_history(self, job_id: str) -> bool:
        found = False
        for suffix in (".json", ".studio.wav", ".pbx.wav"):
            path = self.outputs / f"{job_id}{suffix}"
            if path.exists():
                path.unlink()
                found = True
        with self._lock:
            # Keep _jobs and _order in sync — a stale id left in _order made
            # the queue-position scan KeyError on the next submission.
            self._jobs.pop(job_id, None)
            if job_id in self._order:
                self._order.remove(job_id)
        return found

    def prune_history(self):
        metas = sorted(self.outputs.glob("*.json"),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        for meta_path in metas[HISTORY_KEEP:]:
            job_id = meta_path.stem
            for suffix in (".json", ".studio.wav", ".pbx.wav"):
                (self.outputs / f"{job_id}{suffix}").unlink(missing_ok=True)

    # -- worker --------------------------------------------------------------

    def _run_worker(self):
        log.info("Worker starting; loading model...")
        try:
            self.engine.load()
        except Exception:
            # Engine remembers the error; jobs submitted later fail fast below.
            pass

        while True:
            job_id = self._queue.get()
            with self._lock:
                job = self._jobs.get(job_id)
            if not job:
                continue
            try:
                self._process(job)
            except Exception as e:
                log.exception("Job %s failed", job_id)
                with self._lock:
                    job["status"] = "error"
                    job["error"] = str(e)

    def _process(self, job: dict):
        if not self.engine.is_loaded:
            raise RuntimeError(f"TTS model is not available: {self.engine.load_error or 'still loading'}")

        with self._lock:
            job["status"] = "running"
        t0 = time.time()

        self.engine.set_voice(job["voice_path"])

        pieces = []
        for i, chunk in enumerate(job["chunks"], 1):
            ct0 = time.time()
            pieces.append(self.engine.generate_chunk(chunk, temperature=job["temperature"]))
            with self._lock:
                job["chunks_done"] = i
            log.info("Job %s chunk %d/%d in %.2fs", job["id"], i, job["chunks_total"], time.time() - ct0)

        full = audio_utils.stitch_chunks(pieces)
        duration = round(len(full) / audio_utils.STUDIO_SR, 1)

        (self.outputs / f"{job['id']}.studio.wav").write_bytes(audio_utils.export_studio(full))
        (self.outputs / f"{job['id']}.pbx.wav").write_bytes(audio_utils.export_pbx(full))

        meta = {
            "id": job["id"],
            "text_preview": job["text"][:160] + ("…" if len(job["text"]) > 160 else ""),
            "voice_name": job["voice_name"],
            "duration_sec": duration,
            "created": job["created"],
        }
        (self.outputs / f"{job['id']}.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

        with self._lock:
            job["status"] = "done"
            job["duration_sec"] = duration
        log.info("Job %s done: %.1fs of audio in %.2fs", job["id"], duration, time.time() - t0)
        self.prune_history()
