# syntax=docker/dockerfile:1

# Build args optimized for CPU-only deployment
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1000
ARG GID=1000

# ==============================================================================
# STAGE 1: Frontend Builder
# Purpose: Build the static frontend assets using Node.js.
# ==============================================================================
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS frontend-builder
ARG BUILD_HASH

WORKDIR /app

# Copy only package files to leverage Docker cache
COPY package.json package-lock.json ./
RUN npm ci --force

# Copy the rest of the source code and build
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

# ==============================================================================
# STAGE 2: Backend Python Dependency Builder
# Purpose: Install Python packages in a separate environment with build tools.
# The resulting virtual environment will be copied to the final stage.
# ==============================================================================
FROM python:3.11-slim-bookworm AS backend-builder
ARG UID
ARG GID

# Install build tools and uv
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential gcc python3-dev && \
    pip3 install --no-cache-dir uv && \
    rm -rf /var/lib/apt/lists/*

# Create a virtual environment
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Copy requirements and install packages into the venv
WORKDIR /app
COPY ./backend/requirements.txt ./requirements.txt
RUN uv pip install --system --no-cache-dir -r requirements.txt && \
    uv pip install --system --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# ==============================================================================
# STAGE 3: Final Production Image
# Purpose: Assemble the final lightweight image from the previous stages.
# Base: Alpine Linux for a minimal footprint.
# ==============================================================================
FROM python:3.11-alpine3.20 AS final

ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID
ARG BUILD_HASH

## Environment Configuration ##
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=false \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true \
    # Point to the venv created in the builder stage
    PATH="/opt/venv/bin:$PATH" \
    # Security and Privacy
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    # URL Configuration
    OLLAMA_BASE_URL="http://ollama:11434" \
    OPENAI_API_BASE_URL="" \
    # Model/Cache Configuration - Point to mounted volumes
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/data/whisper" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/data/embedding" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/data/tiktoken" \
    HF_HOME="/app/data/embedding" \
    CHROMA_DB_PATH="/app/data/chroma" \
    # CPU-specific optimizations
    OMP_NUM_THREADS=4 \
    MKL_NUM_THREADS=4

WORKDIR /app/backend

# Install only necessary RUNTIME dependencies for Alpine
RUN apk add --no-cache \
        ffmpeg \
        # For torch/numpy
        libopenblas

# Create non-root user for security
# Alpine's `adduser` is slightly different from Debian's `useradd`
RUN addgroup -g $GID app && \
    adduser -u $UID -G app -h /home/app -s /bin/bash -D app

# Copy the virtual environment from the builder stage
COPY --chown=$UID:$GID --from=backend-builder /opt/venv /opt/venv

# Copy built frontend and backend application code
COPY --chown=$UID:$GID --from=frontend-builder /app/build /app/build
COPY --chown=$UID:$GID --from=frontend-builder /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=frontend-builder /app/package.json /app/package.json
COPY --chown=$UID:$GID ./backend .

# Create directories for mounted volumes and set ownership
# Note: These will be mounted over, but creating them ensures paths exist
RUN mkdir -p /app/data/whisper /app/data/embedding /app/data/tiktoken /app/data/chroma && \
    chown -R $UID:$GID /app /home/app

# Set permissions for OpenShift compatibility
RUN chmod -R g+rwX /app /home/app

# Expose port and switch to non-root user
EXPOSE 8080
USER $UID:$GID

CMD ["bash", "start.sh"]
