#!/bin/bash
# Vast.ai instance control: ./vast.sh status|stop|start
# stop = pause billing for the GPU (disk storage is still billed, ~$0.04/h for 90 GB).
# After start, the SSH port may change: update "Host vastmoshi" in /root/.ssh/config, then
# restart the server (deploy.sh, or ssh vastmoshi /opt/moshirag/deploy/run.sh in the background).
set -euo pipefail
. /root/esys/secrets/moshirag/vast.env
ID=${VAST_INSTANCE_ID:-58180755}
API=https://console.vast.ai/api/v0
case "${1:-status}" in
  status)
    curl -s -H "Authorization: Bearer $VAST_API_KEY" "$API/instances/$ID/" | python3 -c '
import json, sys
i = json.load(sys.stdin)["instances"]
p = i.get("ports", {}).get("22/tcp", [{}])[0].get("HostPort")
print(i["actual_status"], i["gpu_name"], "$%.3f/h" % i["dph_total"], i["public_ipaddr"], "ssh port", p)'
    curl -s -H "Authorization: Bearer $VAST_API_KEY" "$API/users/current/" | python3 -c 'import json,sys; print("credit $%.2f" % json.load(sys.stdin)["credit"])' ;;
  stop|start)
    state=$([ "$1" = stop ] && echo stopped || echo running)
    curl -s -X PUT -H "Authorization: Bearer $VAST_API_KEY" -H 'content-type: application/json' \
      "$API/instances/$ID/" -d "{\"state\":\"$state\"}"; echo ;;
  *) echo "usage: $0 status|stop|start" >&2; exit 2 ;;
esac
