#!/bin/bash
# Stop vLLM. Run this file; do not inline the pattern in an ssh command (it would match that shell).
pkill -f "[v]llm serve"
pkill -f "[E]ngineCore"
sleep 5
true
