#!/bin/bash
# One-time setup of Brilliant Voice AI on an Apple-silicon Mac: Kyutai's Moshi (Moshika voice,
# MLX, 8-bit) with the Brilliant-branded web UI. Needs internet once (~8 GB); start.sh then runs
# offline. This is plain Moshi without retrieval: MoshiRAG itself (rust/moshi-backend on Metal)
# measured 0.10 s per 80 ms frame on an M1 Max, too slow for real time.
# Prerequisites (Homebrew): python@3.12, node. Run from anywhere: deploy/mac/setup.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APP=${BRILLIANT_VOICE_HOME:-$HOME/moshi-mlx}
HF_REPO=${HF_REPO:-kyutai/moshika-mlx-q8}
log() { echo "[setup] $*"; }

PY=$(command -v python3.12 || true)
[ -n "$PY" ] || { echo "missing python3.12 (brew install python@3.12); MLX has no wheels for newer Pythons yet" >&2; exit 1; }
command -v npm >/dev/null || { echo "missing node (brew install node)" >&2; exit 1; }
mkdir -p "$APP"

log "moshi_mlx -> $APP/.venv"
[ -x "$APP/.venv/bin/python" ] || "$PY" -m venv "$APP/.venv"
"$APP/.venv/bin/pip" -q install moshi_mlx huggingface_hub

log "model $HF_REPO (~8 GB, resumable)"
# The Xet transfer backend stalled at a few KB/s on the office link; plain HTTPS ran at ~10 MB/s.
HF_HUB_DISABLE_XET=1 "$APP/.venv/bin/python" - "$HF_REPO" <<'EOF'
import sys, time
from huggingface_hub import hf_hub_download
repo = sys.argv[1]
for f in ["model.q8.safetensors", "tokenizer_spm_32k_3.model", "tokenizer-e351c8d8-checkpoint125.safetensors"]:
    for attempt in range(30):
        try:
            print(hf_hub_download(repo, f), flush=True)
            break
        except Exception as e:
            print(f"retry {f}: {type(e).__name__}", flush=True)
            time.sleep(20)
    else:
        sys.exit(f"could not download {f}")
EOF

log "web UI (Brilliant branding, retrieval texts off) -> $APP/web"
(cd "$ROOT/client" && npm install --no-audit --no-fund && VITE_BRAND_RETRIEVAL=0 npm run build)
rm -rf "$APP/web" && cp -R "$ROOT/client/dist" "$APP/web"
log "done. Start with: $ROOT/deploy/mac/start.sh"
