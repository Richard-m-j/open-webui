# syntax=docker/dockerfile:1

# Build args optimized for CPU-only deployment
ARG USE_OLLAMA=false
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG BUILD_HASH=dev-build
ARG UID=1000
ARG GID=1000

# ==============================================================================
# STAGE 1: Frontend Builder
# ==============================================================================
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS frontend-builder
ARG BUILD_HASH
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --force
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

# ==============================================================================
# STAGE 2: Backend Python Dependency Builder
# ==============================================================================
FROM python:3.11-slim-bookworm AS backend-builder

# Install build tools and uv
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential gcc python3-dev && \
    pip3 install --no-cache-dir uv && \
    rm -rf /var/lib/apt/lists/*

# Create and activate a virtual environment
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Copy requirements and install packages into the venv
WORKDIR /app
COPY ./backend/requirements.txt ./requirements.txt
RUN uv pip install --system --no-cache-dir -r requirements.txt && \
    uv pip install --system --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# ==============================================================================
# STAGE 3: Final Production Image (Using slim-bookworm for reliability)
# ==============================================================================
FROM python:3.11-slim-bookworm AS final

ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID
ARG BUILD_HASH

## Environment Configuration ##
# CORRECTED: Use ARGs directly to prevent expansion errors.
# REMOVED: Secrets are removed and should be passed at runtime.
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=false \
    WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true \
    PATH="/opt/venv/bin:$PATH" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    OLLAMA_BASE_URL="http://ollama:11434" \
    OPENAI_API_BASE_URL="" \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/data/whisper" \
    RAG_EMBEDDING_MODEL=${USE_EMBEDDING_MODEL} \
    RAG_RERANKING_MODEL=${USE_RERANKING_MODEL} \
    SENTENCE_TRANSFORMERS_HOME="/app/data/embedding" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/data/tiktoken" \
    HF_HOME="/app/data/embedding" \
    CHROMA_DB_PATH="/app/data/chroma" \
    OMP_NUM_THREADS=4 \
    MKL_NUM_THREADS=4

WORKDIR /app/backend

# Install only necessary RUNTIME dependencies for Debian-slim
# CORRECTED: Using the correct package name for Debian
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd --gid $GID app && \
    useradd --uid $UID --gid $GID --home /home/app --create-home --shell /bin/bash app

# Copy the virtual environment from the builder stage
COPY --chown=$UID:$GID --from=backend-builder /opt/venv /opt/venv

# Copy built frontend and backend application code
COPY --chown=$UID:$GID --from=frontend-builder /app/build /app/build
COPY --chown=$UID:$GID --from=frontend-builder /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=frontend-builder /app/package.json /app/package.json
COPY --chown=$UID:$GID ./backend .

# Create directories for mounted volumes and set ownership
RUN mkdir -p /app/data/whisper /app/data/embedding /app/data/tiktoken /app/data/chroma && \
    chown -R $UID:$GID /app /home/app

# Set permissions for OpenShift compatibility
RUN chmod -R g+rwX /app /home/app

# Expose port and switch to non-root user
EXPOSE 8080
USER $UID:$GID

CMD ["bash", "start.sh"]
