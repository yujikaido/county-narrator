# County Narrator — Chatterbox Turbo TTS server
#
# Base image pins torch 2.6.0 + CUDA 12.4, matching chatterbox-tts 0.1.7's
# torch pin so pip keeps the CUDA build instead of pulling a replacement.
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

ENV TZ=America/Chicago \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/app/data

# git: some chatterbox deps resolve from VCS; ffmpeg+libsndfile: audio decode;
# tzdata: without it the TZ env is ignored and timestamps come out UTC
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ffmpeg libsndfile1 curl tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY backend /app/backend
COPY frontend /app/frontend
COPY VERSION /app/VERSION

EXPOSE 8000

# Generous start period: first boot downloads ~2 GB of model weights
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/api/health || exit 1

CMD ["python", "-m", "uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
