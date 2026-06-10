"""Chatterbox Turbo wrapper.

Owns the model and the currently-active reference voice. All methods are
called from the single job-worker thread only, so no locking is needed here.
"""
import logging
import threading

import torch

log = logging.getLogger("narrator.engine")


class TTSEngine:
    SAMPLE_RATE = 24000  # S3Gen output rate; confirmed against model.sr after load

    def __init__(self):
        self.model = None
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self._builtin_conds = None
        self._active_voice_path = None
        self._load_error = None
        self._loaded = threading.Event()

    # -- lifecycle -------------------------------------------------------

    def load(self):
        """Download (first run) and load the model. Blocks; call from worker."""
        try:
            from chatterbox.tts_turbo import ChatterboxTurboTTS
            log.info("Loading Chatterbox Turbo on %s ...", self.device)
            self.model = ChatterboxTurboTTS.from_pretrained(device=self.device)
            # Snapshot the built-in voice so we can switch back to it after
            # prepare_conditionals() overwrites model.conds with a custom voice.
            self._builtin_conds = self.model.conds
            log.info("Model loaded (sr=%d, builtin_voice=%s)",
                     self.model.sr, self._builtin_conds is not None)
        except Exception as e:
            self._load_error = str(e)
            log.exception("Model failed to load")
            raise
        finally:
            self._loaded.set()

    @property
    def is_loaded(self):
        return self.model is not None

    @property
    def load_error(self):
        return self._load_error

    def wait_loaded(self, timeout=None):
        return self._loaded.wait(timeout)

    # -- voice selection -------------------------------------------------

    def set_voice(self, voice_path: str | None):
        """Activate a reference voice (or None for the built-in voice).

        Conditionals are prepared once per voice switch, not once per chunk —
        this is the main speed win over the old server, which re-embedded the
        reference clip for every chunk.
        """
        if voice_path == self._active_voice_path:
            return
        if voice_path is None:
            if self._builtin_conds is None:
                raise RuntimeError(
                    "This model build has no built-in voice; upload a reference voice."
                )
            self.model.conds = self._builtin_conds
        else:
            self.model.prepare_conditionals(voice_path)
        self._active_voice_path = voice_path
        log.info("Active voice -> %s", voice_path or "built-in")

    # -- synthesis -------------------------------------------------------

    def generate_chunk(self, text: str) -> torch.Tensor:
        """Synthesize one chunk with the active voice. Returns (1, N) float32."""
        with torch.inference_mode():
            wav = self.model.generate(text)
        if wav.dim() == 1:
            wav = wav.unsqueeze(0)
        return wav.float().cpu()
