#!/bin/bash
# Starts everything MoshiRAG needs inside one container:
#   1. downloads the models into /data on first start (~42 GB, cached afterwards),
#   2. starts the retrieval LLM (vLLM, OpenAI-compatible API on 127.0.0.1:8002),
#   3. starts moshi-backend (web UI + WebSocket API on :8998).
# If either server exits, the container exits so the restart policy can bring it back.
set -euo pipefail

LLM_HF_MODEL=${LLM_HF_MODEL:-Qwen/Qwen3-14B-AWQ}
LLM_SERVED_NAME=${LLM_SERVED_NAME:-qwen3-14b}
LLM_GPU_MEM_GB=${LLM_GPU_MEM_GB:-18}
LLM_MAX_MODEL_LEN=${LLM_MAX_MODEL_LEN:-4096}
MOSHI_HTTPS=${MOSHI_HTTPS:-1}
MOSHI_PORT=${MOSHI_PORT:-8998}
RAG_TIMEOUT=${RAG_TIMEOUT:-3.0}
APP=/opt/moshirag
DATA=/data

log() { echo "[moshirag] $*"; }

nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader || {
  log "no NVIDIA GPU visible: run with --gpus all (NVIDIA Container Toolkit required)"; exit 1; }
GPU_MEM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
if [ "${CC%%.*}" -lt 8 ]; then
  log "GPU compute capability $CC < 8.0: BF16 is not supported, Moshi cannot run on this GPU"; exit 1
fi

mkdir -p "$DATA/logs" "$DATA/certs" "$HF_HOME"

# ---- models -----------------------------------------------------------------------------------
log "checking models in $HF_HOME (first start downloads ~42 GB)"
python3 "$APP/download_models.py" | tail -1
if [ -z "${LLM_BASE_URL:-}" ]; then
  python3 -c "from huggingface_hub import snapshot_download as s; print(s('$LLM_HF_MODEL'))" | tail -1
fi
TOKENIZER=$DATA/llama32-tokenizer.json
if [ ! -s "$TOKENIZER" ]; then
  SRC=$(python3 -c "from huggingface_hub import hf_hub_download as d; print(d('unsloth/Llama-3.2-3B-Instruct', 'tokenizer.json'))")
  python3 "$APP/convert_tokenizer.py" "$SRC" "$TOKENIZER"
fi
# Everything is local from here on.
export HF_HUB_OFFLINE=1

# ---- retrieval LLM ----------------------------------------------------------------------------
pids=()
if [ -z "${LLM_BASE_URL:-}" ]; then
  # vLLM sizes itself as a fraction of total GPU memory; convert the GB budget to that fraction.
  UTIL=$(python3 -c "print(round(min(0.9, $LLM_GPU_MEM_GB * 1024 / $GPU_MEM_MB), 3))")
  log "starting vLLM ($LLM_HF_MODEL, ${LLM_GPU_MEM_GB} GB = $UTIL of ${GPU_MEM_MB} MiB)"
  vllm serve "$LLM_HF_MODEL" \
    --served-model-name "$LLM_SERVED_NAME" \
    --host 127.0.0.1 --port 8002 \
    --gpu-memory-utilization "$UTIL" --max-model-len "$LLM_MAX_MODEL_LEN" --max-num-seqs 4 \
    --default-chat-template-kwargs '{"enable_thinking": false}' \
    > "$DATA/logs/llm.log" 2>&1 &
  pids+=($!)
  for i in $(seq 1 180); do
    curl -s -m 2 http://127.0.0.1:8002/v1/models >/dev/null && break
    kill -0 "${pids[0]}" 2>/dev/null || { tail -30 "$DATA/logs/llm.log"; log "vLLM failed to start"; exit 1; }
    sleep 5
  done
  log "vLLM ready"
  export LLM_BASE_URL=http://127.0.0.1:8002/v1 LLM_MODEL_NAME=$LLM_SERVED_NAME LLM_API_KEY=${LLM_API_KEY:-local}
else
  log "using external retrieval LLM $LLM_BASE_URL (${LLM_MODEL_NAME:?LLM_MODEL_NAME is required})"
fi

# ---- Moshi ------------------------------------------------------------------------------------
python3 - "$APP/config.template.json" "$DATA/config.json" <<EOF
import json, sys
c = json.load(open(sys.argv[1]))
c.update({
    "log_dir": "$DATA/logs",
    "static_dir": "$APP/client",
    "addr": "0.0.0.0",
    "port": int("$MOSHI_PORT"),
    "cert_dir": "$DATA/certs",
    "use_https": "$MOSHI_HTTPS" == "1",
    "rag_timeout": float("$RAG_TIMEOUT"),
    "arc_encoder_tokenizer_path": "$TOKENIZER",
})
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOF
log "starting moshi-backend on $([ "$MOSHI_HTTPS" = 1 ] && echo https || echo http)://0.0.0.0:$MOSHI_PORT"
LD_LIBRARY_PATH=$APP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
  "$APP/bin/moshi-backend" --config "$DATA/config.json" standalone &
pids+=($!)

trap 'kill "${pids[@]}" 2>/dev/null || true' TERM INT
set +e
wait -n "${pids[@]}"
status=$?
log "a server exited (status $status); stopping the container"
kill "${pids[@]}" 2>/dev/null || true
exit "$status"
