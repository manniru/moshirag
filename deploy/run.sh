#!/bin/bash
# Starts the MoshiRAG Rust server on the GPU instance (no systemd inside Vast containers).
set -a; . /opt/moshirag/moshirag.env; set +a
cd /opt/moshirag/rust/moshi-backend
exec /opt/moshirag/rust/target/release/moshi-backend --config config.moshirag.json standalone
