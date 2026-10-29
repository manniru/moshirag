#!/bin/bash
# Stops Brilliant Voice AI: the whole process group start.sh created (local_web and its
# multiprocessing children, which would otherwise keep port 8998).
APP=${BRILLIANT_VOICE_HOME:-$HOME/moshi-mlx}
PGID=$(cat "$APP/server.pgid" 2>/dev/null || true)
if [ -n "$PGID" ] && kill -0 -- "-$PGID" 2>/dev/null; then
  kill -- "-$PGID" && rm -f "$APP/server.pgid" && echo "stopped"
else
  echo "not running"
fi
