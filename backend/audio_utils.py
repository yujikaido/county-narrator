"""Audio post-processing: stitching, normalization, and WAV exports.

Two export targets:
  studio -- 24 kHz / 16-bit PCM / mono   (full quality, for editing/archive)
  pbx    -- 8 kHz / 16-bit PCM / mono    (3CX auto-attendant / voicemail format)

3CX rejects anything that isn't plain PCM WAV at 8 kHz 16-bit mono, which is
why the pbx export exists as a first-class output rather than a separate
conversion step.
"""
import io
import wave

import numpy as np
import torch
import torchaudio

STUDIO_SR = 24000
PBX_SR = 8000

CHUNK_GAP_MS = 200          # silence inserted between stitched chunks
EDGE_FADE_MS = 10           # fade-in/out per chunk so splices never click
TRIM_THRESHOLD_DB = -50.0   # edge-silence trim level
TRIM_PAD_MS = 60            # silence left on each end after trimming
PEAK_TARGET = 0.84          # ~ -1.5 dBFS peak normalization


def _trim_silence(wav: np.ndarray, sr: int) -> np.ndarray:
    """Trim near-silence from both ends, keeping a small natural pad."""
    threshold = 10 ** (TRIM_THRESHOLD_DB / 20.0)
    loud = np.flatnonzero(np.abs(wav) > threshold)
    if loud.size == 0:
        return wav
    pad = int(sr * TRIM_PAD_MS / 1000)
    start = max(0, int(loud[0]) - pad)
    end = min(wav.size, int(loud[-1]) + pad)
    return wav[start:end]


def _edge_fade(wav: np.ndarray, sr: int) -> np.ndarray:
    n = min(int(sr * EDGE_FADE_MS / 1000), wav.size // 2)
    if n > 0:
        ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
        wav[:n] *= ramp
        wav[-n:] *= ramp[::-1]
    return wav


def stitch_chunks(chunks: list[torch.Tensor], sr: int = STUDIO_SR) -> np.ndarray:
    """Combine per-chunk tensors into one normalized mono float32 array."""
    gap = np.zeros(int(sr * CHUNK_GAP_MS / 1000), dtype=np.float32)
    pieces: list[np.ndarray] = []
    for i, chunk in enumerate(chunks):
        wav = chunk.squeeze().numpy().astype(np.float32)
        if wav.ndim > 1:  # safety: collapse any stray channel dim
            wav = wav.mean(axis=0)
        wav = _edge_fade(_trim_silence(wav, sr).copy(), sr)
        if i > 0:
            pieces.append(gap)
        pieces.append(wav)
    full = np.concatenate(pieces) if pieces else np.zeros(1, dtype=np.float32)

    peak = float(np.max(np.abs(full)))
    if peak > 1e-6:
        full = full * (PEAK_TARGET / peak)
    return np.clip(full, -1.0, 1.0)


def _to_pcm16_wav_bytes(wav: np.ndarray, sr: int) -> bytes:
    pcm = (wav * 32767.0).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def export_studio(wav: np.ndarray) -> bytes:
    return _to_pcm16_wav_bytes(wav, STUDIO_SR)


def export_pbx(wav: np.ndarray) -> bytes:
    """Resample to 8 kHz (with anti-aliasing) and write 16-bit PCM mono."""
    tensor = torch.from_numpy(wav).unsqueeze(0)
    down = torchaudio.functional.resample(tensor, STUDIO_SR, PBX_SR)
    down = down.squeeze(0).numpy()
    peak = float(np.max(np.abs(down)))
    if peak > PEAK_TARGET:  # resampling can overshoot slightly
        down = down * (PEAK_TARGET / peak)
    return _to_pcm16_wav_bytes(np.clip(down, -1.0, 1.0), PBX_SR)
