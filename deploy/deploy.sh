#!/bin/bash
# Build and (re)start MoshiRAG on the GPU instance reachable as ssh host "$1" (default: vastmoshi).
# First run: installs packages + Rust, downloads the models, converts the tokenizer.
# Later runs: copies the backend sources and client, rebuilds incrementally, restarts.
# Needs /root/esys/secrets/moshirag/moshirag.env (LLM_* settings for the local vLLM) (copied to the instance as /opt/moshirag/moshirag.env).
set -euo pipefail
HOST=${1:-vastmoshi}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SECRETS=/root/esys/secrets/moshirag

(cd "$REPO/client" && [ -d dist ] || { npm install --no-audit --no-fund && npm run build; })

ssh "$HOST" 'mkdir -p /opt/moshirag/logs /opt/moshirag/deploy'
tar -C "$REPO" --exclude=rust/target -czf - rust client/dist deploy | ssh "$HOST" 'tar -xzf - -C /opt/moshirag'
ssh "$HOST" 'umask 077; cat > /opt/moshirag/moshirag.env' < "$SECRETS/moshirag.env"

ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
if ! command -v cargo >/dev/null && [ ! -x ~/.cargo/bin/cargo ]; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3-pip curl pkg-config libssl-dev build-essential cmake git
  pip install -q -U "huggingface_hub[hf_transfer]"
  curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal
fi
. ~/.cargo/env
rustup default stable >/dev/null
HF_HUB_ENABLE_HF_TRANSFER=1 python3 /opt/moshirag/deploy/download_models.py | tail -1
[ -f /opt/moshirag/llama32-tokenizer.json ] || python3 /opt/moshirag/deploy/convert_tokenizer.py \
  "$(python3 -c 'from huggingface_hub import hf_hub_download as d; print(d("unsloth/Llama-3.2-3B-Instruct","tokenizer.json"))')" \
  /opt/moshirag/llama32-tokenizer.json
# Self-hosted retrieval LLM (vLLM + Qwen3-14B-AWQ), started before Moshi so its memory check
# sees the free GPU memory it expects.
if [ ! -x /opt/vllm/bin/vllm ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
  python3 -m venv /opt/vllm
  /opt/vllm/bin/pip install -q -U pip
  /opt/vllm/bin/pip install -q vllm ninja
fi
HF_HUB_ENABLE_HF_TRANSFER=1 python3 -c 'from huggingface_hub import snapshot_download as s; s("Qwen/Qwen3-14B-AWQ")' >/dev/null
chmod +x /opt/moshirag/deploy/*.sh
if ! curl -s -m 2 127.0.0.1:8002/v1/models >/dev/null; then
  setsid nohup /opt/moshirag/deploy/run-llm.sh > /opt/moshirag/llm.log 2>&1 < /dev/null &
  for i in $(seq 1 100); do curl -s -m 2 127.0.0.1:8002/v1/models >/dev/null && break; sleep 5; done
fi
cd /opt/moshirag/rust
CUDA_COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .) \
  cargo build --features cuda --bin moshi-backend -r 2>&1 | tail -1
# Match the binary path only; a pattern like "moshi-backend --config" also matches this shell.
pkill -x moshi-backend || true
sleep 2
setsid nohup /opt/moshirag/deploy/run.sh > /opt/moshirag/server.log 2>&1 < /dev/null &
for i in $(seq 1 60); do grep -qE 'listening|Error' /opt/moshirag/server.log && break; sleep 3; done
tail -1 /opt/moshirag/server.log
REMOTE
