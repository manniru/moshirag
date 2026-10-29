"""Rewrite a Llama 3.2 tokenizer.json into the layout tokenizers 0.15 (used by moshi-backend) can read.

Newer tokenizer.json files store BPE merges as ["a", "b"] pairs and add "ignore_merges";
tokenizers 0.15 expects "a b" strings and fails with "data did not match any variant of
untagged enum ModelWrapper".
Usage: python3 convert_tokenizer.py <src tokenizer.json> <dst tokenizer.json>
"""
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
tok = json.load(open(src))
model = tok["model"]
if model["merges"] and isinstance(model["merges"][0], list):
    assert not any(" " in a or " " in b for a, b in model["merges"])
    model["merges"] = [f"{a} {b}" for a, b in model["merges"]]
model.pop("ignore_merges", None)
json.dump(tok, open(dst, "w"), ensure_ascii=False)
print(f"wrote {dst} ({len(model['merges'])} merges)")
