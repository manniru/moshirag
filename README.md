# MoshiRAG at Esys (`moshirag.esys.ng`)

This is a deployment fork of [kyutai-labs/moshi-rag](https://github.com/kyutai-labs/moshi-rag)
(blog: <https://kyutai.org/blog/2026-04-30-moshi-rag/>, paper: arXiv 2604.12928). The upstream
README follows below this section, unchanged.

**Live demo:** <https://moshirag.esys.ng>. Open it in Chrome, allow the microphone, use
**headphones** (Moshi listens while it talks), and ask a factual question in English, e.g.
"Who won the FIFA World Cup in 2018, and who was the top scorer?". One conversation at a time.

## Architecture

```
browser ─https/wss─► Cloudflare ─► tunnel esys-proxmox-agent (cloudflared on host esys)
        ─► http://127.0.0.1:18998 on esys (systemd moshirag-tunnel: ssh -L)
        ─► Vast.ai GPU instance 127.0.0.1:8998  moshi-backend (Rust, CUDA, standalone, HTTP)
              ├─ Moshika-RAG 7B  (kyutai/moshika-rag-candle-bf16, BF16)
              ├─ STT 1B          (kyutai/stt-1b-en_fr-candle) for the user transcript
              ├─ ARC4 encoder    (kyutai/ARC4_Encoder_Llama) encodes retrieved references
              ├─ web UI          (client/dist, built with Vite)
              └─ retrieval LLM ─► Anthropic API, claude-haiku-5-5 (OpenAI-compatible endpoint)
```

When Moshi emits its retrieval token (`<ret>`), the backend sends the transcript to Claude,
which answers with a one-line `Reference: ...` (about 1 s). The reference is encoded and
injected into Moshi while it keeps talking.

## Where it runs

| Piece | Where |
| :--- | :--- |
| GPU | Vast.ai instance **58180755** (label `moshirag`): 1x RTX A6000 48 GB, Romania, ~$0.52/h running (incl. 90 GB disk). Image `nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04`, ssh alias `vastmoshi` in `/root/.ssh/config` on esys |
| Code on the instance | `/opt/moshirag` (`rust/`, `client/dist`, `deploy/`), binary `rust/target/release/moshi-backend`, config `rust/moshi-backend/config.moshirag.json`, log `/opt/moshirag/server.log`, env `/opt/moshirag/moshirag.env` (600) |
| Models | Hugging Face cache `/root/.cache/huggingface` on the instance (~33 GB); converted tokenizer `/opt/moshirag/llama32-tokenizer.json` |
| Port forward | esys systemd unit `moshirag-tunnel` (`deploy/moshirag-tunnel.service`): `127.0.0.1:18998` → instance `127.0.0.1:8998` |
| Public | Cloudflare tunnel `esys-proxmox-agent` ingress `moshirag.esys.ng` → `http://127.0.0.1:18998` (no NPM), proxied CNAME in the `esys.ng` zone. Tunnel config backup `secrets/moshirag/tunnel-config-backup-*.json` |
| Secrets (esys, not in git) | `/root/esys/secrets/moshirag/`: `vast.env` (Vast API key), `moshirag.env` (Anthropic key) |

GPU memory use is about 23.7 GB of 48 GB with `batch_size: 1`.

## Changes from upstream

* `rust/moshi-backend/src/rag_manager.rs`: when `LLM_BASE_URL` is `api.anthropic.com`, the
  request drops `stop: ["\n"]` (Anthropic rejects whitespace-only stop sequences) and
  `reasoning_effort`, and sends `thinking: {"type": "disabled"}` (otherwise Claude can spend all
  256 tokens thinking and return an empty reference). The reply is cut at its first newline
  instead. Every reference is logged (`RAG: reference text: ...`), and the raw LLM response is
  logged when the reference is empty.
* `rust/moshi-backend/config.moshirag.json`: Hub paths in `org/repo:file` form, `batch_size: 1`,
  `use_https: false` (TLS ends at Cloudflare), listen on `127.0.0.1`, `rag_timeout: 3.0`
  (upstream 1.5), static dir `/opt/moshirag/client/dist`, converted Llama tokenizer.
* `deploy/convert_tokenizer.py`: the backend uses `tokenizers` 0.15, which cannot read the
  current Llama 3.2 `tokenizer.json` (merges stored as pairs). The script rewrites it to the old
  layout. The source file is the ungated copy `unsloth/Llama-3.2-3B-Instruct` (identical to
  `meta-llama/Llama-3.2-3B-Instruct`, whose licence the `mannir` HF account has also accepted).

## Operating it

```bash
cd /root/esys/moshirag
deploy/vast.sh status          # state, price, ssh port, remaining Vast credit
deploy/vast.sh stop            # pause: stops GPU billing (disk still ~$0.04/h)
deploy/vast.sh start           # resume; then check the ssh port (see below) and start the server
deploy/deploy.sh vastmoshi     # copy code, build (incremental), restart the server
ssh vastmoshi tail -f /opt/moshirag/server.log
```

After `start`, Vast may give the instance a new SSH port or IP: compare `deploy/vast.sh status`
with `Host vastmoshi` in `/root/.ssh/config`, fix it, `systemctl restart moshirag-tunnel`, then
run `deploy/deploy.sh` (or `ssh vastmoshi 'setsid nohup /opt/moshirag/deploy/run.sh >
/opt/moshirag/server.log 2>&1 < /dev/null &'`). The server does not start by itself after a
resume: Vast containers have no systemd. Model loading takes about 40 s; the site answers
502 until then.

If Vast credit runs out, Vast stops the instance and may delete it with its disk. Rebuilding
from scratch on a new instance takes about 15 minutes: rent a 48 GB Ampere-or-newer GPU
(BF16 is required, so no Turing/Volta cards), add it as `vastmoshi`, run `deploy/deploy.sh`.

Do not `pkill -f "moshi-backend --config"` over ssh: the pattern also matches the ssh shell
itself. Use `pkill -x moshi-backend`.

## Testing

`tests/ws_e2e.py` streams a WAV file to the WebSocket API in real time and prints Moshi's text,
the reference text it received, and timing:

```bash
python3 -m venv /tmp/mrv && /tmp/mrv/bin/pip install sphn websockets numpy
/tmp/mrv/bin/python tests/ws_e2e.py wss://moshirag.esys.ng/api/chat tests/question_worldcup_2018.wav
```

Measured on 2026-10-29 from esys: first audio after 0.35 s, audio streamed at real-time
speed, Claude references in 0.8-2.0 s. It only works when no browser session is open
(`batch_size: 1`).

Limits: English only, one female voice (Moshika), one user at a time, and the retrieval
trigger sometimes fires before the question is fully transcribed.

---

# MoshiRAG: Asynchronous Knowledge Retrieval for Full-Duplex Speech Language Models

![precommit badge](https://github.com/kyutai-labs/moshi-rag/workflows/precommit/badge.svg)
![rust ci badge](https://github.com/kyutai-labs/moshi-rag/workflows/Rust%20CI/badge.svg)

[[Read the paper]][moshi-rag] [[Hugging Face]](https://hf.co/collections/kyutai/moshirag-release)

[MoshiRAG][moshi-rag] is a compact **full-duplex** speech language model augmented with asynchronous knowledge retrieval to improve factuality without sacrificing real-time interactivity. Built on top of [Moshi][moshi] and [Mimi][moshi], MoshiRAG predicts when a query needs external knowledge, retrieves references within the natural response delay, and grounds answers in stronger knowledge sources.

This repository is based on the [Moshi repo](https://github.com/kyutai-labs/moshi), augmented with RAG-related implementation.
Please visit the original Moshi repo if you would like to test the original Moshi model.

## Organisation of the repository

This repository includes two main codebases:

- **[PyTorch](#pytorch-implementation)** for research and experimentation, located in [`moshi/`](moshi/).
- **[Rust](#rust-implementation)** for production use, located in [`rust/`](rust/).

Finally, the code for the web UI client is provided in the [`client/`](client/) directory.
 
## System design

MoshiRAG uses a modular front-end/back-end design:
- **Front-end** is a full-duplex speech model based on Moshi that handles real-time conversation.
- **Back end** is an asynchronous retrieval system running in parallel to fetch factual information when needed.

The front end keeps listening and speaking continuously. When the model predicts a retrieval trigger token, conversation context is sent to the retrieval back end while the dialogue continues.  During this period, the model can produce lightweight pre-RAG content (for example, short acknowledgments or coarse responses) so the interaction stays natural.

The back end is text-in/text-out and can be implemented with different retrieval methods (LLM-based retrieval or search-based retrieval, etc).  The retrieval back end takes conversation context (derived by combining the text predicted by Moshi inner monologue and the user transcription predicted by a streaming ASR component) as inputs, and then returns the reference text. Once the retrieval is completed, the reference text is encoded and injected back into Moshi as a stream, allowing later response segments to be grounded in external knowledge without interrupting the ongoing conversation.

<p align="center">
<img src="./front_back_end.png" alt="Illustration of the front-end and back-end components in MoshiRAG. When the model needs external information, it outputs a <ret> token. The conversation transcript is sent to the back end which operates asynchronously. Once ready, the result is injected into Moshi which then adapts its response with no interruption."
width="650px"></p>

<p align="center">
<img src="./streams.png" alt="Text and audio token streams of the inputs and outputs of MoshiRAG. Front-end Moshi receives at all time its previous step token predictions and the user speech tokens. When the retrieval result is ready, its representation is summed with the embeddings from other token streams and ingested over a number of time steps."
width="650px"></p>


## Models

We release the MoshiRAG model fine-tuned on a female synthetic voice (Moshika). Here is the list of associated HuggingFace repos of the model in different formats.

- MoshiRAG (Moshika) for PyTorch (bf16): [kyutai/moshika-rag-pytorch-bf16](https://huggingface.co/kyutai/moshika-rag-pytorch-bf16), .
- MoshiRAG (Moshika) for Rust/Candle (bf16): [kyutai/moshika-rag-candle-bf16](https://huggingface.co/kyutai/moshika-rag-candle-bf16).

All models are released under the CC-BY 4.0 license.

## Requirements

You will need at least Python 3.10, with 3.12 recommended. For specific requirements, please check the individual backends
directories. You can install the PyTorch and MLX clients with the following:

```bash
pip install -U -e "git+https://git@github.com/kyutai-labs/moshi-rag.git#egg=moshi&subdirectory=moshi"
pip install rustymimi  # mimi, rust implementation with Python bindings from PyPI
```

If you are not using Python 3.12, you might get an error when installing `ruVstymimi`. Then, you will need to install the [Rust toolchain](https://rustup.rs/), or switch to Python 3.12.

While we hope that the present codebase will work on Windows, we do not provide official support for it. At the moment, we do not support quantization for the PyTorch version, so you will need a GPU with a significant amount of memory (24GB) for the front-end Moshi model. The reference encoder can run on a second GPU, or on the **same GPU** as Moshi if you have enough VRAM. The back end can be run either on a local device or a web API can be used. An additional GPU is required if the back end is run locally.

For using the Rust backend, you will need a recent version of the [Rust toolchain](https://rustup.rs/).
To compile GPU support, you will also need the [CUDA](https://developer.nvidia.com/cuda-toolkit) properly installed for your GPU, in particular with `nvcc`.

## PyTorch implementation

The PyTorch based API can be found in the `moshi` directory.

### Back end (retrieval LLM)

It is recommended to run a local OpenAI-compatible LLM with vLLM so retrieval stays low-latency and stable. MoshiRAG is sensitive to retrieval delays over 3 seconds; slower or flaky APIs can hurt response quality.

Example vLLM (served on port `8002`; set `LLM_BASE_URL` to `http://localhost:8002/v1` and `LLM_MODEL_NAME` to `google/gemma-3-27b-it`):

```bash
vllm serve google/gemma-3-27b-it --host 0.0.0.0 --port 8002
```

Alternatively, if you wish to use online APIs, feel free to skip this server but do configurate `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL_NAME` properly when running the front end. Choosing low-latency API provider significantly stabilizes MoshiRAG's performance.

### Front end (main Moshi server + reference encoder)

To run MoshiRAG interactively with the web UI, you start two cooperating processes:

1. **Main Moshi server** (`python -m moshi.moshi.server`) — full-duplex speech model. It calls out to a retrieval LLM over HTTP (OpenAI-compatible API) when RAG triggers.
2. **Reference text encoder** (`python -m moshi.moshi.server_conditioner`) — a separate service that encodes retrieved reference strings so they can be injected into Moshi's conditioning path (`REFERENCE_ENCODER_URL` points at this service).

This split keeps the conversational stack modular. The Moshi model and reference encoder can run on the same GPU if you have enough memory, or on separate GPUs (but ideally on the same machine). The main server also streams user audio to an STT (speech-to-text / streaming ASR) endpoint to transcribe user speech into text.

Set the environment variables appropriately before starting the main server (replace placeholders with your keys and endpoints):

| Variable | Role |
| -------- | ---- |
| `REFERENCE_ENCODER_URL` | Base URL of the reference text conditioner (e.g. `http://localhost:8001`). |
| `STT_URL` | Streaming ASR API. We recommend [Gradium](https://gradium.ai/) `wss://eu.api.gradium.ai/api/speech/asr`. Not necessary if `--gradium-stt` is not set and a local STT model will be run instead. |
| `STT_API_KEY` | API key for the STT service of Gradium. Not necessary if `--gradium-stt` is not set and a local STT model will be run instead. |
| `LLM_BASE_URL` | Base URL of the OpenAI-compatible API used for retrieval. We recommend using a local VLLM server. |
| `LLM_API_KEY` | API key for the retrieval LLM. |
| `LLM_MODEL_NAME` | Model id passed to the retrieval API. |
| `MOSHI_RETRIEVAL_LLMS_JSON` | Optional multi-backend retrieval config. When set, it overrides single-backend retrieval selection. |

**1. Start the reference text encoder** (config and checkpoints can be downloaded from [Hugging Face](https://huggingface.co/kyutai/moshika-rag-pytorch-bf16) ):

```bash
python -m moshi.moshi.server_conditioner \
    --config hf://kyutai/moshika-rag-pytorch-bf16/config.json \
    --moshi-weight hf://kyutai/moshika-rag-pytorch-bf16/model.safetensors \
    --cuda-device 0 \
    --conditioner reference_with_time \
    --port 8001
```

**2. Start the main server**:

```bash
export REFERENCE_ENCODER_URL=http://localhost:8001
export STT_URL=wss://eu.api.gradium.ai/api/speech/asr
export STT_API_KEY=YOUR_API_KEY
export LLM_BASE_URL=http://localhost:8002/v1
export LLM_API_KEY=dummy
export LLM_MODEL_NAME=google/gemma-3-27b-it

python -m moshi.moshi.server \
  --gradio-tunnel \
  --static "./client/dist" \
  --init-active-speaker model \
  --gradium-stt
```

You can also configure multiple retrieval backends with `MOSHI_RETRIEVAL_LLMS_JSON`, which overrides single `LLM_BASE_URL`/`LLM_MODEL_NAME` selection for retrieval calls. Example:

```bash
export MOSHI_RETRIEVAL_LLMS_JSON='[{"id": "gpt-oss-20b", "base_url": "https://api.groq.com/openai/v1", "model": "openai/gpt-oss-20b", "prompt_style": "simplified"},  {"id": "gemma-3-27b-it", "base_url": "http://localhost:8002/v1", "model": "google/gemma-3-27b-it", "default": true, "prompt_style": "original"}]'
export LLM_API_KEY=YOUR_API_KEY
export REFERENCE_ENCODER_URL=http://localhost:8001
export STT_URL=wss://eu.api.gradium.ai/api/speech/asr
export STT_API_KEY=YOUR_API_KEY

python -m moshi.moshi.server \
  --gradio-tunnel \
  --static "./client/dist" \
  --init-active-speaker model \
  --gradium-stt
```

- Each array item is one retrieval profile (`id`, `base_url`, `model`, optional `api_key`, optional `prompt_style`).
- `default: true` marks the fallback profile (exactly one required when there are 2+ profiles) which will be used if any retrieval model fails.
- `prompt_style` controls which bundled reference prompt template is used for that profile (`original` or `simplified`; default is `original` for local LLM instances).
- If a profile omits `api_key`, the global `LLM_API_KEY` is used (as in the example).

Run the conditioner, the retrieval LLM (when local), and the main server on the same machine when you can, to reduce networking issues and simplify debugging.

### Web UI

Access the web UI on [localhost:8998](http://localhost:8998).
If your GPU is on a distant machine this will not work because for security reasons, websites using HTTP
are not allowed to use the microphone. There are two ways to get around this:
- Forward the remote 8998 port to your localhost using ssh `-L` flag. Then
  connects to [localhost:8998](http://localhost:8998) as mentioned previously.
- Use the `--gradio-tunnel` argument, setting up a tunnel with a URL accessible from anywhere.
  Keep in mind that this tunnel goes through the US and can add significant
  latency (up to 500ms from Europe). You can use `--gradio-tunnel-token` to set a
  fixed secret token and reuse the same address over time.

Accessing a server that is not localhost via http may cause issues with using
the microphone in the web UI (in some browsers this is only allowed using
https).

### Inference script

We also provide an inference script which runs the PyTorch MoshiRAG pipeline on a folder of WAV audio files, and writes output WAVs and JSON logs to the specified destination. Set up `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL_NAME` as previously mentioned for MoshiRAG to obtain reference text.

```bash
export REFERENCE_ENCODER_URL=http://localhost:8001
export LLM_BASE_URL=http://localhost:8002/v1
export LLM_API_KEY=dummy
export LLM_MODEL_NAME=google/gemma-3-27b-it

python -m moshi.moshi.run_inference \
  --input-dir INPUT_DIR \
  --output-dir OUTPUT_DIR \
  --max-consecutive-silence-frames 40
```


## Rust implementation

In order to run the Rust inference server, set up environment variables `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL_NAME`, and use the following command from within the `rust` directory:

```bash
export LLM_BASE_URL=http://localhost:8002/v1
export LLM_API_KEY=dummy
export LLM_MODEL_NAME=google/gemma-3-27b-it

cargo run --features cuda --bin moshi-backend -r -- --config moshi-backend/config.json standalone
```

When using macOS, you can replace `--features cuda` with `--features metal`.
Refer to `rust/README.md` for more details regarding the config.

Once the server has printed 'standalone worker listening', you can use the web
UI. By default the Rust server uses https so it will be at
[localhost:8998](https://localhost:8998).

You will get warnings about the site being unsafe. When using chrome you
can bypass these by selecting "Details" or "Advanced", then "Visit this unsafe
site" or "Proceed to localhost (unsafe)."

## License

The present code is provided under the MIT license for the Python parts, and Apache license for the Rust backend.
The web client code is provided under the MIT license.
Note that parts of this code is based on [AudioCraft](https://github.com/facebookresearch/audiocraft), released under
the MIT license.

The weights for the models are released under the CC-BY 4.0 license.

## Citation

Please cite the following paper if you find this implementation useful.

```
@misc{chien2026moshirag,
      title={MoshiRAG: Asynchronous Knowledge Retrieval for Full-Duplex Speech Language Models}, 
      author={Chung-Ming Chien and Manu Orsini and Eugene Kharitonov and Neil Zeghidour and Karen Livescu and Alexandre D{\'e}fossez},
      year={2026},
      eprint={2604.12928},
      archivePrefix={arXiv},
      primaryClass={cs.CL},
      url={https://arxiv.org/abs/2604.12928}, 
}
```

[moshi]: https://arxiv.org/abs/2410.00037
[moshi-rag]: https://arxiv.org/abs/2604.12928