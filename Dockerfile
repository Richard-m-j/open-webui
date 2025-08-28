# syntax=docker/dockerfile:1

# Build args optimized for CPU-only deployment
ARG USE_CUDA=false
ARG USE_OLLAMA=false
# Lightweight embedding model for CPU performance
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1000
ARG GID=1000

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# Install git for build hash
RUN apk add --no-cache git

# Copy package files first for better layer caching
COPY package.json package-lock.json ./
RUN npm ci --force

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## WebUI backend ########
FROM python:3.11-slim-bookworm AS base

ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID
ARG BUILD_HASH

## Environment Configuration - CPU Optimized ##
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=false \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true

## URL Configuration - Optimized for your docker-compose setup ##
# Point to your external Ollama container
ENV OLLAMA_BASE_URL="http://ollama:11434" \
    OPENAI_API_BASE_URL=""

## Security and Privacy Configuration ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

## Model Configuration - CPU Optimized ##
# Use base whisper model for better CPU performance
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models" \
    # CPU-specific optimizations
    OMP_NUM_THREADS=4 \
    MKL_NUM_THREADS=4 \
    NUMBA_CACHE_DIR="/tmp/numba_cache"

WORKDIR /app/backend

# Create non-root user for security
RUN groupadd --gid $GID app && \
    useradd --uid $UID --gid $GID --home /home/app --create-home --shell /bin/bash app

# Create necessary directories with CPU-optimized structure
RUN mkdir -p /home/app/.cache/chroma \
             /app/backend/data/cache/whisper/models \
             /app/backend/data/cache/embedding/models \
             /app/backend/data/cache/tiktoken \
             /tmp/numba_cache && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id

# Install system dependencies - minimal CPU-only set
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        pandoc \
        gcc \
        netcat-openbsd \
        curl \
        jq \
        python3-dev \
        ffmpeg \
        libsm6 \
        libxext6 \
        libblas3 \
        liblapack3 \
        libopenblas-dev && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

# Copy and install Python dependencies
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# CPU-optimized Python package installation
RUN pip3 install --no-cache-dir --upgrade pip uv && \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Pre-download models optimized for CPU performance
RUN python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])" && \
    python -c "import torch; torch.set_num_threads(4); print('CPU threads set to 4')"

# Since USE_OLLAMA=false, we skip Ollama installation entirely

# Copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# Copy backend files
COPY --chown=$UID:$GID ./backend .

# Set proper ownership
RUN chown -R $UID:$GID /app /home/app

# Security: Set proper permissions for OpenShift compatibility
RUN chmod -R g+rwX /app /home/app && \
    find /app -type d -exec chmod g+s {} + && \
    find /home/app -type d -exec chmod g+s {} +

# Expose port
EXPOSE 8080

# Switch to non-root user
USER $UID:$GID

CMD ["bash", "start.sh"]
