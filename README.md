# Spare Cores Inspector Data

Data collected by [`sparecores-inspector`](https://github.com/SpareCores/sc-inspector)
under the `data` folder using the `vendor/server` directory structure, referring to the
vendor by its `vendor_id`, and using the `api_reference` for the server.


# Collected data

In general, consult the [SpareCores Inspector](https://github.com/SpareCores/sc-inspector)
repository for the technical details about the data collected, and the
[Spare Cores Navigator Benchmark Coverage](https://sparecores.com/navigator/benchmark-workloads)
page for a higher level overview.

## Timing

Each inspected instance may have a `timing/` directory (alongside task directories such as
`dmidecode/`). Orchestration state for the timing task lives in `timing/meta.json`. Per GitHub
Actions run, timestamps are stored under `timing/<GITHUB_RUN_ID>/` so repeated starts of the same
instance type keep separate histories.

Files are plain text with a single UTC timestamp per line, in ISO-8601 form
(`YYYY-MM-DDTHH:MM:SSZ`). They are written to separate files (not `meta.json`) so the GitHub
Actions start workflow and the remote `inspect` run can commit independently. The run id comes from
the `GITHUB_RUN_ID` environment variable.

| File | Stage | Written by |
|------|--------|------------|
| `api_start` | Start of successful Pulumi `runner.create` (per attempt, lock retries excluded) | Start workflow (`inspector start`) |
| `api_end` | Successful `runner.create` return | Start workflow |
| `user_data_start` | First line of `user_data.sh` on the host | Host user-data script |
| `user_data_end` | Immediately before `docker run inspect` on the host | Host user-data script |
| `inspector_start` | `inspector.py inspect` begins | Inspect container |
| `inspector_end` | `inspector.py inspect` finishes (all tasks done) | Inspect container |
| `machine_start` | Estimated OS boot time (`now − /proc/uptime`, second resolution) | Inspect container (`timing` task) |

Example layout:

```
data/upcloud/STARTER-2xCPU-2GB/timing/
  meta.json
  12345678901/
    api_start
    api_end
    user_data_start
    user_data_end
    inspector_start
    inspector_end
    machine_start
  12345678902/
    ...
```

The timing task uses two inspector task flags (see `sc-inspector`):

- **`start_with_instance`** — never starts an instance on its own; may be added to a start when
  another task is already starting the machine, and uses the usual `meta.json` rules on inspect.
- **`always_run`** — never starts an instance on its own; is always added when any other task
  starts the machine, and always runs on inspect (ignoring a previous successful `meta.json`).

Timing sets both flags. A machine is therefore never started for timing alone; whenever it starts
for another task, timing runs and writes a full checkpoint set under `timing/<GITHUB_RUN_ID>/`.

## PassMark

### Benchmark numbers

See [this forum entry](https://forums.passmark.com/performancetest/4599-formula-cpu-mark-memory-mark-and-disk-mark/page2#post54964).

### Viewing PassMark output

PassMark's [PerformanceTest](https://www.passmark.com/products/pt_linux/download.php) needs a terminal and prints its output with [ANSI escape codes](https://github.com/SpareCores/sc-inspector-data/blob/e49a5d4efe496e77ac8721e6b7910b138a2dff41/data/aws/r5.large/passmark/stderr#L1).

To view this output, you can use for example [ttyplay](https://manpages.ubuntu.com/manpages/noble/man1/ttyplay.1.html) if the file won't render correctly in your terminal
using a simple `cat`.

## vLLM serving (`vllm/`)

Inspector task **`vllm`** collects **production-style LLM serving** performance on each instance.
Results are stored under `data/<vendor>/<api_reference>/vllm/` (`stdout`, `stderr`, `meta.json`),
same layout as other tasks.

This is separate from the **`llm`** task ([`benchmark-llm`](https://github.com/SpareCores/sc-images/tree/main/images/benchmark-llm)),
which uses **llama.cpp / llama-bench** and reports isolated **prompt-processing** and
**text-generation** throughput (tokens/sec) for GGUF models. That data powers the classic
SmolLM / Qwen / Gemma charts on the Navigator. **vLLM answers a different question:** how well does
this machine run a **real vLLM HTTP server** under concurrent load?

### Why we benchmark vLLM this way

- **[vLLM](https://github.com/vllm-project/vllm)** is a common way to serve models in production
  (OpenAI-compatible API, batching, GPU tensor parallelism).
- Raw llama-bench numbers do **not** translate to serving latency, saturation, or multi-request
  behavior. vLLM metrics are what operators care about when hosting an API.
- Load generation uses **[GuideLLM](https://github.com/vllm-project/guidellm)** (recommended by
  upstream vLLM for production-style tests), not hand-rolled `vllm bench serve` loops. GuideLLM runs
  profiles such as **synchronous** (one user), **throughput** (saturate the server), and **sweep**
  (interpolate rates between those extremes).

Implementation lives in
[`sc-images/vllm-common/benchmark.py`](https://github.com/SpareCores/sc-images/tree/main/vllm-common/benchmark.py);
images are `benchmark-vllm-gpu`, `benchmark-vllm-cpu`, and `benchmark-vllm-cpu-avx2`.

### How the inspector picks an image

The task tries Docker images **in order** until `--probe-only` succeeds (smallest model loads,
`/health` OK):

1. **`benchmark-vllm-gpu`** — NVIDIA GPU, all visible GPUs via `--tensor-parallel-size`
2. **`benchmark-vllm-cpu`** — Hub CPU image (amd64 needs **AVX-512**; also **arm64**)
3. **`benchmark-vllm-cpu-avx2`** — amd64 **AVX2-only** hosts (custom base built with
   `VLLM_CPU_AVX2=true`)

The first image that passes the probe runs the **full** benchmark; there is no fallback mid-run.
Task timeout is **3 hours** (GuideLLM sweeps × models × workloads).

### Architectures covered

| Platform | Image | Notes |
|----------|--------|--------|
| amd64 + GPU | `benchmark-vllm-gpu` | Multi-GPU tensor parallel |
| arm64 + GPU | `benchmark-vllm-gpu` | Hub `vllm/vllm-openai` (multi-arch) |
| amd64 CPU (AVX-512) | `benchmark-vllm-cpu` | Hub `vllm-openai-cpu` |
| arm64 CPU | `benchmark-vllm-cpu` | Hub `vllm-openai-cpu` |
| amd64 CPU (AVX2 only) | `benchmark-vllm-cpu-avx2` | After Hub CPU probe fails on AVX2-only x86 |

### Models and workloads (default ladder)

**Models** (largest that fits in available GPU VRAM or CPU RAM; ladder stops if throughput
collapses):

- SmolLM2-135M, Qwen2.5-0.5B, Gemma-2-2B, Llama-3.1-8B (gated; needs `HF_TOKEN`)
- Phi-4 and Llama-3.3-70B **bnb-4bit** on GPU-class memory only

**Workloads** (synthetic token lengths per GuideLLM run):

| Workload | Prompt tokens | Output tokens | Typical use |
|----------|---------------|---------------|-------------|
| `chat` | 256 | 128 | Short assistant turn |
| `rag` | 1024 | 256 | Context + answer |
| `long` | 4096 | 512 | Long context (GPU only) |

On **CPU and GPU**, GuideLLM uses a **`sweep`** profile (default **3** steps: sync → saturated
throughput → one constant rate). Use `GUIDELLM_SWEEP_SIZE=2` for sync+throughput only, or
`GUIDELLM_PROFILES=legacy` for the old sync + capped-throughput path.

### Runtime vs `llm/` (from `meta.json`)

There is **no `vllm/` data in this repo yet**; the table below compares inspector timeouts and
observed **`llm`** wall times (`start` → `end` in `data/.../llm/meta.json`, **2 958** successful
runs) to **expected** `vllm` cost from a manual GPU test (SmolLM2-135M on UpCloud 1×L4).

| | **`llm`** (`benchmark-llm`) | **`vllm`** (`benchmark-vllm-*`) |
|--|---------------------------|--------------------------------|
| **Task timeout** | 1.5 h | 3 h (+ up to 18 min per failed image **probe**) |
| **What runs** | 6 GGUF models; llama-bench prompt-processing + text-generation (~11 token sizes) | Up to 6 HF models; `vllm serve` + GuideLLM per workload (GPU: chat/rag/long × sweep) |
| **`stdout` size** | ~15–40 KB typical full ladder (~30–40 JSONL lines, one row per bench scenario) | ~185 KB for **one** small GPU model (~320 JSONL metric rows) |
| **Typical successful run** | **median ~35 min** (p90 ~42 min, max ~73 min) when most of the ladder completes | **~12 min per GPU model** measured (SmolLM2-135M, 3 workloads); scales with model count |
| **Same host class (UpCloud 1×L4)** | **~7 min** (18 lines, **2** GGUF models — VRAM stops the ladder early) | **~12–15 min** for one HF model; **~25–40 min** if the vLLM ladder matches those 2–4 small models |
| **Large GPU (e.g. 1×L40S, full ladder)** | **~40 min** (42 lines, **6** GGUF models) | **~1–1.5 h** rough estimate (6 models × ~12 min; 70B/Phi steps can add more) |
| **CPU-only instances** | Same **~30–45 min** band for 5–6 GGUF models (llama.cpp CPU) | Often **slower than `llm`** per machine: CPU `vllm serve` startup + 4 models × 2 workloads × 2 GuideLLM profiles (no `long`, but real HTTP load) |

**Takeaways:** `llm` is usually **one continuous 30–45 minute** job on instances that fit most GGUF
models. `vllm` emits **far more metrics per model** and repeats **server startup + concurrent load**
per workload; on **small GPUs** both tasks finish in **under ~15 minutes** because only small
models run, but **`vllm` is not faster** — it is **heavier per model** and needs the **3 h** cap for
full ladders on large GPUs (Phi-4, 70B bnb, multi-GPU). Inspector **`vllm`** also runs a **probe**
before the timed benchmark; that phase is not stored in `data/.../vllm/`.

### What appears in `stdout` (JSONL)

**Only JSONL metrics go to `stdout`** — one JSON object per line, all with
`benchmark=vllm_serving`. [`sc-crawler`](https://github.com/SpareCores/sc-crawler) reads this file
when `meta.json` has `exit_code: 0` and loads Navigator **LLM serving** benchmarks (not `llm_speed`).

Human-readable harness logs, vLLM server messages, and GuideLLM progress go to **`stderr`** (see
below). Do not expect a pretty table on `stdout`.

| Kind | Field(s) | Meaning |
|------|----------|---------|
| Latency | `ttft`, `tpot`, `itl`, `e2el` | Time to first token, per-output-token, inter-token, end-to-end (ms) |
| Throughput | `output_throughput`, `total_throughput`, `request_throughput` | Mean under load; `percentile` is `null` |
| Workload | `workload`, `prompt_tokens`, `output_tokens` | `chat` / `rag` / `long` (GPU runs all three) |
| GuideLLM step | `profile`, `strategy`, `target_rate`, `concurrency` | e.g. `profile=sweep`, `strategy` ∈ `synchronous`, `throughput`, `constant` |
| Latency stats | `percentile` | `p50`, `p95`, `p99`, or `mean` for latency rows only |
| Model | `model`, `model_id` | Ladder short id (e.g. `smol-135m`) and Hugging Face repo id |
| Host / stack | `mode`, `arch`, `avx512`, `avx2_only_image`, `gpu_count`, `gpu_model`, `tensor_parallel`, `total_vram_gb`, `vllm_version`, `guidellm_version` | How and where the server ran |

**`model` naming:** the default ladder uses short ids (`smol-135m`, `qwen-0.5b`, …). If the harness
is invoked with `--models <hf-repo-id>`, `model` is the repo basename (e.g. `SmolLM2-135M-Instruct`);
`model_id` is always the full Hugging Face id.

**Row volume (GPU, one ladder model):** a full GPU run emits on the order of **~95 rows for
`chat`**, **~114 for `rag`**, and **~114 for `long`** under `profile=sweep` (roughly **320 lines**
total for SmolLM2-135M). Multiple ladder models append more lines until the ladder stops.

Example (from a real `benchmark-vllm-gpu` run on NVIDIA L4, single model, `chat` / synchronous step):

```json
{
  "benchmark": "vllm_serving",
  "model": "smol-135m",
  "model_id": "HuggingFaceTB/SmolLM2-135M-Instruct",
  "workload": "chat",
  "prompt_tokens": 256,
  "output_tokens": 128,
  "profile": "sweep",
  "strategy": "synchronous",
  "target_rate": null,
  "concurrency": 0.999,
  "measurement": "ttft",
  "percentile": "p50",
  "score": 10.16,
  "unit": "ms",
  "mode": "gpu",
  "arch": "amd64",
  "avx512": true,
  "avx2_only_image": false,
  "vllm_version": "0.22.0",
  "guidellm_version": "0.6.0",
  "tensor_parallel": 1,
  "gpu_count": 1,
  "gpu_model": "NVIDIA L4",
  "total_vram_gb": 23.66
}
```

### What appears in `stderr`

| Content | When |
|---------|------|
| Harness `INFO` (mode, arch, versions, memory, CPU flags) | Start of run |
| `Starting server: vllm serve …` | Each model |
| `GuideLLM: guidellm benchmark run …` | Each workload / profile |
| `GuideLLM emitted N rows model=… workload=…` | After each GuideLLM JSON report is parsed |
| `probe_ok model=… mode=…` | **`--probe-only`** runs only (inspector probe phase; not repeated in full benchmark `stderr`) |
| vLLM `APIServer` / worker lines | Server subprocess (volume varies) |
| Python `resource_tracker` / `shared_memory` warnings | Often at vLLM shutdown; harmless cleanup noise |

The inspector stores **only the full benchmark container** output in `data/.../vllm/stdout` and
`stderr`. Image **probe** attempts that fail are not committed; a successful probe is followed by
a second run whose logs are what you see in the repo.

### What this is not

- **Not comparable 1:1 with `llm/` llama-bench charts** — different stack (GGUF vs HF weights),
  different metrics (isolated prefill/gen tok/s vs TTFT/TPOT under concurrency).
- **Gated HF repos** — Gemma-2B and Llama-3.1-8B need license acceptance on Hugging Face and
  `HF_TOKEN` in the inspector environment. 70B uses public
  `unsloth/Llama-3.3-70B-Instruct-bnb-4bit` (ungated on Hub), aligned with the GGUF ladder spirit.
- **Not a substitute for application-specific SLO tuning** — we use fixed workloads and GuideLLM
  defaults so instances are comparable on the Navigator; operators should still validate their
  own prompts and rates.

For image build pins, env vars (`GUIDELLM_SWEEP_SIZE`, `GUIDELLM_PROFILES`, probe overrides), and harness details, see
[`sc-images/vllm-common/README.md`](https://github.com/SpareCores/sc-images/tree/main/vllm-common).
