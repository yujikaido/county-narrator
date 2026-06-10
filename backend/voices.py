"""Voice library: named reference clips stored on disk with a JSON index.

Each upload becomes an immutable file (uuid filename), so a voice's content
never changes under a path the model may have processed before — this designs
away the stale-conditionals bug the old server worked around by copying the
reference clip to a fresh path on every single request.
"""
import json
import logging
import threading
import time
import uuid
from pathlib import Path

import librosa

log = logging.getLogger("narrator.voices")

MIN_DURATION_SEC = 5.5   # model asserts > 5.0s; keep a safety margin
MAX_DURATION_SEC = 120.0
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
ALLOWED_EXTENSIONS = {".wav", ".mp3", ".m4a", ".flac", ".ogg"}


class VoiceError(ValueError):
    pass


class VoiceStore:
    def __init__(self, voices_dir: Path):
        self.dir = voices_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.index_path = self.dir / "voices.json"
        self._lock = threading.Lock()
        self._voices = self._read_index()

    def _read_index(self) -> dict:
        if self.index_path.exists():
            try:
                entries = json.loads(self.index_path.read_text(encoding="utf-8"))
                # Drop index entries whose audio file disappeared
                return {v["id"]: v for v in entries if (self.dir / v["filename"]).exists()}
            except (json.JSONDecodeError, KeyError):
                log.exception("voices.json unreadable; starting with empty library")
        return {}

    def _write_index(self):
        tmp = self.index_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(list(self._voices.values()), indent=2), encoding="utf-8")
        tmp.replace(self.index_path)

    def list(self) -> list[dict]:
        with self._lock:
            return sorted(self._voices.values(), key=lambda v: v["created"], reverse=True)

    def get(self, voice_id: str) -> dict | None:
        with self._lock:
            return self._voices.get(voice_id)

    def path_for(self, voice_id: str) -> Path | None:
        voice = self.get(voice_id)
        return (self.dir / voice["filename"]) if voice else None

    def add(self, name: str, original_filename: str, data: bytes) -> dict:
        name = name.strip()
        if not name:
            raise VoiceError("Voice needs a name.")
        if len(data) > MAX_UPLOAD_BYTES:
            raise VoiceError(f"File exceeds {MAX_UPLOAD_BYTES // (1024 * 1024)} MB limit.")
        ext = Path(original_filename or "").suffix.lower()
        if ext not in ALLOWED_EXTENSIONS:
            raise VoiceError(f"Unsupported file type '{ext}'. Use: {', '.join(sorted(ALLOWED_EXTENSIONS))}")

        voice_id = uuid.uuid4().hex[:12]
        filename = f"{voice_id}{ext}"
        path = self.dir / filename
        path.write_bytes(data)

        # Validate by decoding the actual audio, not guessing from file size.
        try:
            duration = float(librosa.get_duration(path=str(path)))
        except Exception:
            path.unlink(missing_ok=True)
            raise VoiceError("Could not decode this file as audio.")
        if duration < MIN_DURATION_SEC:
            path.unlink(missing_ok=True)
            raise VoiceError(
                f"Clip is {duration:.1f}s — the model needs more than 5 seconds "
                f"of reference audio. Upload a clip of at least {MIN_DURATION_SEC:.0f}s."
            )
        if duration > MAX_DURATION_SEC:
            path.unlink(missing_ok=True)
            raise VoiceError(f"Clip is {duration:.0f}s; keep reference clips under {MAX_DURATION_SEC:.0f}s "
                             "(only the first ~10s are used anyway).")

        voice = {
            "id": voice_id,
            "name": name,
            "filename": filename,
            "duration_sec": round(duration, 1),
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        with self._lock:
            self._voices[voice_id] = voice
            self._write_index()
        log.info("Voice added: %s (%r, %.1fs)", voice_id, name, duration)
        return voice

    def delete(self, voice_id: str) -> bool:
        with self._lock:
            voice = self._voices.pop(voice_id, None)
            if not voice:
                return False
            (self.dir / voice["filename"]).unlink(missing_ok=True)
            self._write_index()
        log.info("Voice deleted: %s (%r)", voice_id, voice["name"])
        return True
