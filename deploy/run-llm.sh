#!/bin/bash
# Self-hosted retrieval LLM: vLLM (OpenAI-compatible API on 127.0.0.1:8002) on the same GPU as Moshi.
# Uses about 18 GB of the A6000's 48 GB; Moshi + STT + encoder use about 24 GB.
export PATH=/opt/vllm/bin:$PATH
# FlashInfer's JIT sampler needs an nvcc matching torch's CUDA (13.x); the image ships 12.4.
export VLLM_USE_FLASHINFER_SAMPLER=0
MODEL=${LLM_HF_MODEL:-Qwen/Qwen3-14B-AWQ}
NAME=${LLM_SERVED_NAME:-qwen3-14b}
exec vllm serve "$MODEL" \
  --served-model-name "$NAME" \
  --host 127.0.0.1 --port 8002 \
  --gpu-memory-utilization 0.38 --max-model-len 4096 --max-num-seqs 4 \
  --default-chat-template-kwargs '{"enable_thinking": false}'
