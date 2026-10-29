"""Pre-download every model file the MoshiRAG config uses into the Hugging Face cache (~33 GB)."""
from huggingface_hub import hf_hub_download

FILES = [
    ("kyutai/moshika-rag-candle-bf16", "model.safetensors"),
    ("kyutai/moshika-rag-candle-bf16", "tokenizer-e351c8d8-checkpoint125.safetensors"),
    ("kyutai/moshika-rag-candle-bf16", "tokenizer_spm_32k_3.model"),
    ("kyutai/stt-1b-en_fr-candle", "model.safetensors"),
    ("kyutai/stt-1b-en_fr-candle", "tokenizer_en_fr_audio_8000.model"),
    ("kyutai/stt-1b-en_fr-candle", "mimi-pytorch-e351c8d8@125.safetensors"),
    ("kyutai/stt-1b-en_fr-candle", "config.json"),
    ("kyutai/ARC4_Encoder_Llama", "model.safetensors"),
    # Same file as meta-llama/Llama-3.2-3B-Instruct, without the licence gate.
    ("unsloth/Llama-3.2-3B-Instruct", "tokenizer.json"),
]
for repo, name in FILES:
    print(hf_hub_download(repo, name), flush=True)
print("DONE")
