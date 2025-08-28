# syntax=docker/dockerfile:1

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH
WORKDIR /app

# NOTE: Using a .dockerignore file is highly recommended to prevent
# copying unnecessary files (like .git, .vscode, etc.) into the image.
RUN apk add --no-cache git
COPY package.json package-lock.json ./

# WARNING: --force is used here, which can hide underlying dependency issues.
# It's better to fix conflicts in package-lock.json and remove --force.
RUN npm ci --force

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build


######## Python Builder Stage ########
# FIX: Use a Debian-based image for glibc, which is required by the official PyTorch wheels.
FROM python:3.11-slim-bookworm AS python-builder

# FIX: Declare build arguments and provide a sensible default to prevent build failures.
ARG USE_EMBEDDING_MODEL="all-MiniLM-L6-v2"
ARG UID
ARG GID

WORKDIR /app/backend

# FIX: Use apt-get for Debian-based image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential pandoc gcc curl jq \
        python3-dev ffmpeg libsm6 libxext6 \
        libblas3 liblapack3 libopenblas-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements first for better layer caching
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

# Build backend binary with PyInstaller
RUN pyinstaller --onefile start.py \
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
# FIX: Use a Debian-based slim image to match the builder's glibc environment.
# This prevents binary incompatibility errors with the PyInstaller executable.
FROM debian:bookworm-slim AS runtime

ARG UID=1000
ARG GID=1000
WORKDIR /app

# FIX: Use apt-get for Debian and install equivalent minimal dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libstdc++6 \
        libgcc-s1 \
        libopenblas0 \
        bash \
        curl \
        jq \
        git \
        tini \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy frontend build
COPY --from=build /app/build /app/build
COPY --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=build /app/package.json /app/package.json

# Copy backend binary + model cache + start.sh
COPY --from=python-builder /app/backend/dist/backend_app /app/backend_app
COPY --from=python-builder /app/backend/data /app/backend/data
COPY --from=python-builder /app/backend/start.sh /app/start.sh

# Security: non-root user
RUN addgroup -g $GID app && \
    adduser --system --disabled-password --no-create-home --uid $UID --ingroup app app && \
    chown -R app:app /app && \
    chmod +x /app/start.sh
USER app

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
