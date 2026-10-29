# MoshiRAG all-in-one image: Moshika-RAG 7B + STT + ARC4 encoder (Rust moshi-backend, CUDA),
# web UI, and a self-hosted retrieval LLM (vLLM + Qwen3-14B-AWQ). Models are downloaded into the
# /data volume on first start. Build from the repository root:
#   docker build -f docker/Dockerfile -t moshirag .
ARG CUDA_BUILD_IMAGE=nvidia/cuda:12.9.1-devel-ubuntu22.04
ARG VLLM_IMAGE=vllm/vllm-openai:v0.31.0-cu129

# ---- web client -------------------------------------------------------------------------------
FROM node:20-bookworm-slim AS client
WORKDIR /src/client
COPY client/package.json client/package-lock.json ./
RUN npm install --no-audit --no-fund
COPY client/ ./
RUN npm run build

# ---- Rust backend -----------------------------------------------------------------------------
FROM ${CUDA_BUILD_IMAGE} AS backend
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl ca-certificates pkg-config libssl-dev build-essential cmake git \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH=/root/.cargo/bin:$PATH
# PTX for compute capability 8.0 is JIT-compiled on newer GPUs (A100, A6000, RTX 30/40/50,
# L4/L40S, H100, ...). BF16 needs 8.0 or newer, so Turing/Volta cards are not supported.
ARG CUDA_COMPUTE_CAP=80
ENV CUDA_COMPUTE_CAP=${CUDA_COMPUTE_CAP}
WORKDIR /src/rust
COPY rust/ ./
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/src/rust/target \
    cargo build --features cuda --bin moshi-backend --profile release-no-debug \
    && mkdir -p /out/lib \
    && cp target/release-no-debug/moshi-backend /out/ \
    && cp -P /usr/local/cuda/lib64/libcublas.so.12* /usr/local/cuda/lib64/libcublasLt.so.12* \
             /usr/local/cuda/lib64/libcurand.so.10* /out/lib/

# ---- runtime ----------------------------------------------------------------------------------
FROM ${VLLM_IMAGE}
ENV HF_HOME=/data/hf \
    HF_HUB_ENABLE_HF_TRANSFER=0 \
    VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1 \
    VLLM_USE_FLASHINFER_SAMPLER=0
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libssl3 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=backend /out/moshi-backend /opt/moshirag/bin/moshi-backend
COPY --from=backend /out/lib/ /opt/moshirag/lib/
COPY --from=client /src/client/dist/ /opt/moshirag/client/
COPY rust/moshi-backend/config.moshirag.json /opt/moshirag/config.template.json
COPY deploy/convert_tokenizer.py deploy/download_models.py docker/entrypoint.sh /opt/moshirag/
RUN chmod +x /opt/moshirag/entrypoint.sh
VOLUME /data
EXPOSE 8998
HEALTHCHECK --interval=30s --timeout=5s --start-period=30m \
    CMD curl -skf "$( [ "${MOSHI_HTTPS:-1}" = 1 ] && echo https || echo http )://127.0.0.1:8998/" >/dev/null || exit 1
ENTRYPOINT ["/opt/moshirag/entrypoint.sh"]
