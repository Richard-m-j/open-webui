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

######## Stage 1: WebUI Frontend Build ########
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

######## Stage 2: Python Backend Builder (PyInstaller) ########
FROM python:3.11-alpine3.20 AS py-builder

# Install build-time system dependencies for Alpine
RUN apk add --no-cache \
    build-base \
    git \
    pandoc \
    ffmpeg \
    openblas-dev \
    gcc

WORKDIR /app

# Set environment variables required for model download
ENV RAG_EMBEDDING_MODEL=${USE_EMBEDDING_MODEL} \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME=${USE_TIKTOKEN_ENCODING_NAME} \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

# Copy and install Python dependencies, including pyinstaller
COPY ./backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip uv && \
    pip install --no-cache-dir pyinstaller && \
    # Install torch for CPU on Alpine
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Copy backend source code
COPY ./backend ./backend

# Pre-download all models so they can be bundled by PyInstaller
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"

# Compile the application using PyInstaller
# We bundle the entire data cache (models) and the migrations folder into the executable
RUN pyinstaller --noconfirm --onefile --name webui \
    --add-data "backend/data/cache:data/cache" \
    --add-data "backend/migrations:migrations" \
    backend/main.py


######## Stage 3: Final Production Image ########
FROM alpine:3.20 AS final

ARG UID
ARG GID
ARG BUILD_HASH
ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL

# Create non-root user for security
# Using -D for "no password", -s for shell, -h for home dir
RUN addgroup -g $GID app && \
    adduser -u $UID -G app -h /home/app -s /bin/bash -D app

# Install only essential RUNTIME system dependencies
RUN apk add --no-cache \
    bash \
    ffmpeg \
    pandoc \
    openblas \
    netcat-openbsd \
    curl \
    jq

WORKDIR /app

# Environment Configuration
# These are needed at runtime by the compiled binary
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=false \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    WEBUI_BUILD_VERSION=${BUILD_HASH} \
    DOCKER=true \
    OLLAMA_BASE_URL="http://ollama:11434" \
    OPENAI_API_BASE_URL="" \
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    # Point cache dirs to locations INSIDE the container that the app expects
    WHISPER_MODEL_DIR="/app/data/cache/whisper/models" \
    SENTENCE_TRANSFORMERS_HOME="/app/data/cache/embedding/models" \
    TIKTOKEN_CACHE_DIR="/app/data/cache/tiktoken" \
    HF_HOME="/app/data/cache/embedding/models" \
    # Set runtime thread counts
    OMP_NUM_THREADS=4 \
    MKL_NUM_THREADS=4

# Create necessary directories for runtime data (e.g., ChromaDB)
RUN mkdir -p /home/app/.cache/chroma && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id

# Copy compiled backend binary from the builder stage
COPY --from=py-builder /app/dist/webui /app/webui

# Copy built frontend assets from the frontend build stage
COPY --from=build /app/build /app/build
COPY --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --from=build /app/package.json /app/package.json

# Set ownership for all application and data directories
RUN chown -R $UID:$GID /app /home/app

# Security: Set proper permissions for OpenShift compatibility
RUN chmod -R g+rwX /app /home/app && \
    find /app -type d -exec chmod g+s {} + && \
    find /home/app -type d -exec chmod g+s {} +

# Expose port and switch to non-root user
EXPOSE 8080
USER $UID:$GID

# The CMD now simply executes the self-contained binary
CMD ["./webui"]
