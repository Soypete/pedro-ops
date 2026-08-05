# Moonshine v2 speech-to-text, exposed over the OpenAI audio API.
#
# CPU-only by design: the cluster has no GPU nodes. Moonshine runs on
# onnxruntime, so this needs no CUDA layer.
FROM python:3.12-slim-bookworm

# ffmpeg: transcodes whatever the browser records (webm/ogg) to 16 kHz mono.
# libportaudio2: moonshine-voice depends on sounddevice, which dlopens
#   PortAudio at import time even though this server never touches a mic.
#   Without it the import fails outright.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        libportaudio2 \
    && rm -rf /var/lib/apt/lists/*

ARG MOONSHINE_MODEL=small-streaming
ARG MOONSHINE_LANGUAGE=en
ENV MOONSHINE_MODEL=${MOONSHINE_MODEL} \
    MOONSHINE_LANGUAGE=${MOONSHINE_LANGUAGE} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Non-root, and the model cache must live somewhere that user owns.
RUN useradd --create-home --uid 10001 moonshine
ENV XDG_CACHE_HOME=/home/moonshine/.cache

# Bake the weights into the image so pods never fetch from the network at
# startup -- a cold pull would blow past the readiness probe and makes the
# deployment dependent on an external host being up.
RUN mkdir -p /home/moonshine/.cache && chown -R moonshine:moonshine /home/moonshine
USER moonshine
RUN python -c "\
from moonshine_voice import get_model_for_language, string_to_model_arch; \
import os; \
name, arch = get_model_for_language(os.environ['MOONSHINE_LANGUAGE'], string_to_model_arch(os.environ['MOONSHINE_MODEL'])); \
print('baked model:', name, arch)"

COPY --chown=moonshine:moonshine app.py .

EXPOSE 8000

# Single worker on purpose: inference is serialised behind an asyncio lock
# because Moonshine is not proven thread-safe. Scale with replicas.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
