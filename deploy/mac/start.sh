#!/bin/bash
# Starts Brilliant Voice AI on the Mac, fully offline, and opens http://localhost:8998.
# Stop with deploy/mac/stop.sh. Log: ~/moshi-mlx/server.log
set -euo pipefail
APP=${BRILLIANT_VOICE_HOME:-$HOME/moshi-mlx}
HF_REPO=${HF_REPO:-kyutai/moshika-mlx-q8}
[ -x "$APP/.venv/bin/python" ] && [ -d "$APP/web" ] || { echo "run deploy/mac/setup.sh first" >&2; exit 1; }
if curl -s -m 2 -o /dev/null http://127.0.0.1:8998/; then echo "already running: http://localhost:8998"; exit 0; fi

# Everything is in the local Hugging Face cache; never contact the Hub. local_web serves from
# multiprocessing children that outlive their parent, so run it in its own process group
# (set -m) and let stop.sh kill the whole group.
set -m
HF_HUB_OFFLINE=1 nohup "$APP/.venv/bin/python" -m moshi_mlx.local_web --hf-repo "$HF_REPO" -q 8 \
  --static "$APP/web" --host 127.0.0.1 --port 8998 --no-browser > "$APP/server.log" 2>&1 &
echo $! > "$APP/server.pgid"
set +m
for _ in $(seq 1 90); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:8998/ && break
  sleep 2
done
curl -s -m 2 -o /dev/null http://127.0.0.1:8998/ || { tail -20 "$APP/server.log"; echo "failed to start" >&2; exit 1; }
# The page answers before the model finishes loading; give it a moment before the first session.
echo "ready: http://localhost:8998 (use headphones; first session after ~20 s)"
[ "${NO_BROWSER:-0}" = 1 ] || open http://localhost:8998
