# syntax=docker/dockerfile:1

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH
WORKDIR /app

RUN apk add --no-cache git
COPY package.json package-lock.json ./
RUN npm ci --force

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build


######## Python Builder Stage ########
FROM python:3.11-slim-bookworm AS python-builder

ARG USE_EMBEDDING_MODEL
ARG UID
ARG GID

WORKDIR /app/backend

# Install system deps needed for build
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential pandoc gcc curl jq \
        python3-dev ffmpeg libsm6 libxext6 \
        libblas3 liblapack3 libopenblas-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements first
COPY ./backend/requirements.txt ./requirements.txt

# Install pip deps + pyinstaller
RUN pip install --no-cache-dir --upgrade pip uv pyinstaller && \
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Environment for pre-downloading models
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL=$USE_EMBEDDING_MODEL \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

# Pre-download models
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('${RAG_EMBEDDING_MODEL}', device='cpu')" && \
    python -c "from faster_whisper import WhisperModel; WhisperModel('${WHISPER_MODEL}', device='cpu', compute_type='int8', download_root='${WHISPER_MODEL_DIR}')" && \
    python -c "import tiktoken; tiktoken.get_encoding('${TIKTOKEN_ENCODING_NAME}')"

# Copy backend source
COPY ./backend .

# Build backend binary with PyInstaller (main.py is the entrypoint)
RUN pyinstaller --onefile main.py \
    --name backend_app \
    --clean --strip \
    --hidden-import torch \
    --hidden-import sentence_transformers \
    --hidden-import faster_whisper \
    --hidden-import tiktoken \
    --collect-all torch \
    --collect-all sentence_transformers \
    --collect-all faster_whisper \
    --collect-all tiktoken


######## Final Runtime Stage ########
FROM alpine:3.20 AS runtime

ARG UID=1000
ARG GID=1000
WORKDIR /app

# Minimal runtime dependencies
RUN apk add --no-cache \
    ffmpeg \
    libstdc++ \
    libgcc \
    openblas \
    bash \
    curl \
    jq \
    git \
    tini \
    ca-certificates

# Copy frontend build
COPY --from=build /app/build /app/build
COPY --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=build /app/package.json /app/package.json

# Copy backend binary + model cache + start.sh
COPY --from=python-builder /app/backend/dist/backend_app /app/backend_app
COPY --from=python-builder /app/backend/data /app/backend/data
COPY --from=python-builder /app/backend/start.sh /app/start.sh

# Patch start.sh to call binary instead of python
RUN sed -i 's|python .*|/app/backend_app|' /app/start.sh && chmod +x /app/start.sh

# Security: non-root user
RUN addgroup -g $GID app && \
    adduser -D -u $UID -G app app && \
    chown -R app:app /app
USER app

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/start.sh"]
