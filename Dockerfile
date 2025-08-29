# syntax=docker/dockerfile:1

# ==============================================================================
# ===== Stage 1: Build Arguments & Global Configuration ========================
# ==============================================================================
# Define build arguments once at the top for clarity and reuse across stages.
# These are optimized for a CPU-only deployment.
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1000
ARG GID=1000

# ==============================================================================
# ===== Stage 2: Frontend Builder ==============================================
# ==============================================================================
# This stage builds the static frontend assets.
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS frontend-builder
ARG BUILD_HASH

WORKDIR /app

# Install git just for getting the build hash, it won't be in the final image.
RUN apk add --no-cache git

# Copy package files and install dependencies to leverage Docker layer caching.
COPY package.json package-lock.json ./
RUN npm ci --force

# Copy the rest of the source code and build the application.
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

# ==============================================================================
# ===== Stage 3: Backend Builder & Model Downloader ============================
# ==============================================================================
# This stage installs Python dependencies and pre-downloads all necessary models.
# It includes build-time tools that are discarded and not included in the final image.
FROM python:3.11-slim-bookworm AS backend-builder
ARG RAG_EMBEDDING_MODEL
ARG WHISPER_MODEL
ARG WHISPER_MODEL_DIR
ARG TIKTOKEN_ENCODING_NAME
ARG SENTENCE_TRANSFORMERS_HOME
ARG HF_HOME
ARG TIKTOKEN_CACHE_DIR

WORKDIR /app/backend

# Set environment variables required for model downloading.
ENV RAG_EMBEDDING_MODEL=${RAG_EMBEDDING_MODEL} \
    WHISPER_MODEL=${WHISPER_MODEL} \
    WHISPER_MODEL_DIR=${WHISPER_MODEL_DIR} \
    TIKTOKEN_ENCODING_NAME=${TIKTOKEN_ENCODING_NAME} \
    SENTENCE_TRANSFORMERS_HOME=${SENTENCE_TRANSFORMERS_HOME} \
    HF_HOME=${HF_HOME} \
    TIKTOKEN_CACHE_DIR=${TIKTOKEN_CACHE_DIR}

# Install build-time system dependencies needed to compile Python packages.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        gcc \
        python3-dev \
        libopenblas-dev && \
    rm -rf /var/lib/apt/lists/*

# Create a virtual environment for clean dependency management.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Install Python dependencies into the virtual environment.
COPY ./backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip uv && \
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Create cache directories before downloading models.
RUN mkdir -p ${SENTENCE_TRANSFORMERS_HOME} ${WHISPER_MODEL_DIR} ${TIKTOKEN_CACHE_DIR}

# Pre-download and cache all models and tokenizers.
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('${RAG_EMBEDDING_MODEL}', device='cpu')" && \
    python -c "from faster_whisper import WhisperModel; WhisperModel('${WHISPER_MODEL}', device='cpu', compute_type='int8', download_root='${WHISPER_MODEL_DIR}')" && \
    python -c "import tiktoken; tiktoken.get_encoding('${TIKTOKEN_ENCODING_NAME}')"

# ==============================================================================
# ===== Stage 4: Final Production Image ========================================
# ==============================================================================
# This is the final, lean production image. It copies artifacts from the
# previous stages and only includes necessary runtime dependencies.
FROM python:3.11-slim-bookworm

ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID
ARG BUILD_HASH

## Environment Configuration
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=false \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true

## URL Configuration
ENV OLLAMA_BASE_URL="http://ollama:11434" \
    OPENAI_API_BASE_URL=""

## Security and Privacy Configuration
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

## Model and Path Configuration
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models" \
    NUMBA_CACHE_DIR="/tmp/numba_cache"

## CPU Performance Configuration
ENV OMP_NUM_THREADS=4 \
    MKL_NUM_THREADS=4

WORKDIR /app/backend

# Install only essential RUNTIME system dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libsm6 \
        libxext6 \
        libblas3 \
        liblapack3 \
        netcat-openbsd && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

# Create the non-root user and group.
RUN groupadd --gid $GID app && \
    useradd --uid $UID --gid $GID --home /home/app --create-home --shell /bin/bash app

# Create directories and set initial ownership.
RUN mkdir -p /home/app/.cache/chroma \
             /app/backend/data \
             /tmp/numba_cache && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id && \
    chown -R $UID:$GID /app /home/app /tmp/numba_cache

# Copy the virtual environment with Python packages from the backend-builder stage.
ENV VIRTUAL_ENV=/opt/venv
COPY --chown=$UID:$GID --from=backend-builder $VIRTUAL_ENV $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Copy the pre-downloaded models and caches from the backend-builder stage.
COPY --chown=$UID:$GID --from=backend-builder /app/backend/data/cache /app/backend/data/cache

# Copy the built frontend assets from the frontend-builder stage.
COPY --chown=$UID:$GID --from=frontend-builder /app/build /app/build
COPY --chown=$UID:$GID --from=frontend-builder /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=frontend-builder /app/package.json /app/package.json

# Copy the backend application code.
COPY --chown=$UID:$GID ./backend .

# Ensure consistent ownership and set group permissions for OpenShift compatibility.
RUN chown -R $UID:$GID /app /home/app && \
    chmod -R g+rwX /app /home/app && \
    find /app -type d -exec chmod g+s {} + && \
    find /home/app -type d -exec chmod g+s {} +

# Expose port and switch to the non-root user.
EXPOSE 8080
USER $UID:$GID

# Set the command to start the application.
CMD ["bash", "start.sh"]