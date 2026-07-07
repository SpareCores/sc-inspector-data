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

1. **`benchmark-vllm-gpu`** — NVIDIA GPU (`--gpus all`; largest valid
   `--tensor-parallel-size` per model — not always every GPU; see
   [Tensor parallelism](#tensor-parallelism))
2. **`benchmark-vllm-cpu`** — Hub CPU image (amd64 needs **AVX-512**; also **arm64**)
3. **`benchmark-vllm-cpu-avx2`** — amd64 **AVX2-only** hosts (custom base built with
   `VLLM_CPU_AVX2=true`)

The first image that passes the probe runs the **full** benchmark; there is no fallback mid-run.
Task timeout is **3 hours** (GuideLLM sweeps × models × workloads). Instances with **under 4 GiB**
RAM skip the task (`exit_code: -2`; task `minimum_memory` is 4 GiB).

### Architectures covered

| Platform | Image | Notes |
|----------|--------|--------|
| amd64 + GPU | `benchmark-vllm-gpu` | Tensor parallel when head count allows; 70B bnb uses pipeline parallel |
| arm64 + GPU | `benchmark-vllm-gpu` | Hub `vllm/vllm-openai` (multi-arch) |
| amd64 CPU (AVX-512) | `benchmark-vllm-cpu` | Hub `vllm-openai-cpu` |
| arm64 CPU | `benchmark-vllm-cpu` | Hub `vllm-openai-cpu` |
| amd64 CPU (AVX2 only) | `benchmark-vllm-cpu-avx2` | After Hub CPU probe fails on AVX2-only x86 |

### Tensor parallelism

vLLM requires `num_attention_heads % tensor_parallel_size == 0`. On multi-GPU hosts the harness
picks the largest valid TP ≤ GPU count (e.g. SmolLM2-135M has **9** heads → **TP=1** on 2 GPUs, so
only one GPU is busy — still `mode=gpu`). JSONL rows carry `tensor_parallel` (TP used) and
`gpu_count` (visible GPUs). Full table:
[`sc-images/vllm-common/README.md` — Tensor parallelism](https://github.com/SpareCores/sc-images/tree/main/vllm-common#tensor-parallelism).

### Models and workloads (default ladder)

**Models** (small → large; each step runs only if `model_fits` RAM/VRAM and the server passes
`/health`; ladder stops on OOM, failed health, or insufficient memory):

- SmolLM2-135M, Qwen2.5-0.5B, Gemma-2-2B, Llama-3.1-8B, Phi-4
- Llama-3.3-70B **bnb-4bit** (~48 GiB) — **GPU only** (bitsandbytes quant)

On **CPU**, every model except 70B may run when RAM allows (including Phi-4). Gemma-2B and
Llama-3.1-8B are gated on Hugging Face — set `HF_TOKEN` and accept each license or those steps
fail health quickly.

**Workloads** (synthetic token lengths per GuideLLM run):

| Workload | Prompt tokens | Output tokens | Typical use |
|----------|---------------|---------------|-------------|
| `chat` | 256 | 128 | Short assistant turn |
| `rag` | 1024 | 256 | Context + answer |
| `long` | 4096 | 512 | Long context (GPU only) |

On **CPU and GPU**, GuideLLM uses a **`sweep`** profile (default **3** steps: sync → saturated
throughput → one constant rate). Use `GUIDELLM_SWEEP_SIZE=2` for sync+throughput only, or
`GUIDELLM_PROFILES=legacy` for the old sync + capped-throughput path. CPU runs cap GuideLLM at
**25 requests** per profile step (`GUIDELLM_MAX_REQUESTS_CPU`).

### Runtime vs `llm/` (from `meta.json`)

| | **`llm`** (`benchmark-llm`) | **`vllm`** (`benchmark-vllm-*`) |
|--|---------------------------|--------------------------------|
| **Task timeout** | 1.5 h | 3 h (+ probe time per failed image, not stored) |
| **What runs** | 6 GGUF models; llama-bench prompt-processing + text-generation (~11 token sizes) | Up to 6 HF models; `vllm serve` + GuideLLM per workload (GPU: chat/rag/long × sweep; CPU: chat/rag × sweep) |
| **`stdout` size** | ~15–40 KB typical full ladder (~30–40 JSONL lines) | **~152 JSONL lines per GPU model** (38 chat + 57 rag + 57 long under `sweep`); **~367 KB** for four models on 1×L40S |
| **Typical successful run** | **median ~35 min** when most of the ladder completes | **~8–12 min per small GPU model**; **~45 min** for four models on 1×L40S (observed) |
| **Same host class (UpCloud 1×L4, GPU broken → CPU)** | **~7 min** (2 GGUF models) | **~23 min** CPU fallback; 3 small models with legacy profiles |
| **Large GPU (1×L40S, full ladder)** | **~40 min** (6 GGUF models) | **~1–2 h** if all six HF models complete; phi-4 / 70B need headroom (~34 GiB / ~48 GiB) |
| **CPU-only instances** | **~30–45 min** for 5–6 GGUF models | Often **slower per machine**: CPU `vllm serve` startup + up to 5 models × 2 workloads × sweep |

**Takeaways:** `vllm` emits **far more metrics per model** than `llm` and repeats **server startup +
concurrent HTTP load** per workload. A full GPU ladder needs the **3 h** timeout. The harness also
runs a **probe** (`--probe-only`) before the timed benchmark; probe logs are not committed.

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

**Row volume (GPU, one ladder model):** under `profile=sweep`, observed on UpCloud 1×L40S:
**~38 rows for `chat`**, **~57 for `rag`**, **~57 for `long`** (**~152 lines** per model).
Multiple ladder models append more lines until the ladder stops. Some sweep steps emit
`score: 0.0` rows (`strategy=throughput` or `constant` with `concurrency: 0.0`) — normal GuideLLM
sweep padding, not a failed benchmark.

Example (from `GPU-8xCPU-64GB-1xL40S`, `chat` / synchronous sweep step):

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
  "score": 9.44,
  "unit": "ms",
  "mode": "gpu",
  "arch": "amd64",
  "avx512": true,
  "avx2_only_image": false,
  "vllm_version": "0.22.1",
  "guidellm_version": "0.6.0",
  "tensor_parallel": 1,
  "gpu_count": 1,
  "gpu_model": "NVIDIA L40S",
  "total_vram_gb": 47.67
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
| `Invalid HTTP request received` | Occasional uvicorn warning (host networking, client disconnect); harmless if isolated |
| `Server health check failed for …` | Model skipped; ladder continues or ends if nothing left |
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

## Postgres multi-VM benchmarks

Database benchmarks run on a **two-VM stack**: a DB host runs Postgres 18; a companion client VM
runs the benchmark container against the DB over the private network. Both VMs share one Pulumi
stack keyed by the DB instance (`data/<vendor>/<db_instance>/`).

| Task | Workload | Cache tier | Durability | Typical timeout |
|------|----------|------------|------------|-----------------|
| `hammerdb_postgres_multi_oltp_mixed_c100` | HammerDB TPROC-C | C100 (1.0) | **async** | 60 min |
| `hammerdb_postgres_multi_oltp_mixed_c30` | HammerDB TPROC-C | C30 (0.3) | **async** | 120 min |
| `hammerdb_postgres_multi_oltp_mixed_durable_c100` | HammerDB TPROC-C | C100 (1.0) | durable | 60 min |
| `benchbase_postgres_multi_read_heavy_c100` | BenchBase wikipedia | C100 | durable | 60 min |
| `benchbase_postgres_multi_crud_simple_c100` | BenchBase ycsb | C100 | **async** | 60 min |
| `hammerdb_postgres_multi_olap_c100` | HammerDB TPC-H | C100 | durable | 120 min |

### Durability tiers

Write-heavy workloads (HammerDB TPROC-C, BenchBase ycsb) on Postgres are **commit-latency bound**:
with `synchronous_commit=on`, every transaction waits for a WAL `fsync`, so throughput can track the
provisioned disk's fsync latency rather than the instance's CPU/memory. Measured on
`Standard_F16ams_v6`, OLTP on both the DB host (~5–12% of 16 vCPUs) and the client stayed near-idle
while ~30k NOPM was gated purely by commit latency — i.e. the durable score mostly ranks the **disk
product**, not the compute instance.

Read-heavy workloads (BenchBase wikipedia, HammerDB TPC-H) keep **`durable`** (production-default
`synchronous_commit=on`). TPC-H scoring is read-only, so durability does not affect QphH; wikipedia
is mostly reads, so commit latency is rarely the bottleneck.

- **`async` (headline, comparable):** the timed run sets **`synchronous_commit=off`** on the server.
  `fsync` stays **on**, so the cluster is never at risk of corruption (worst case on crash is the
  loss of the last few hundred ms of commits — irrelevant for an ephemeral benchmark VM). This
  removes the fsync wait from the commit path, so the score reflects CPU / memory / lock scaling and
  is comparable across clouds regardless of storage tier. Used for OLTP and ycsb headline scores.
- **`durable` (secondary or default):** production-default **`synchronous_commit=on`**. For OLTP there
  is a separate disclosed task (`…_durable_c100`) that reflects real-world durable-commit throughput on
  that instance's disk. It is **disk-dependent** and must **not** be used to compare compute across
  instances/clouds.

OLTP async and durable scores are stored under `benchmark_id = hammerdb_postgres_multi:nopm` and
distinguished by the `durability` (and `cache_tier`) fields in `metrics.json`'s config. BenchBase
scores use `benchbase_postgres_multi:tpm` with the same `durability` field. `fsync` is never disabled.

### DB disk tiers

Because the durable metric and schema build depend on storage, the inspector requests faster SSD
for **only the multi-VM DB host**: Azure `Premium_LRS`, GCP `pd-ssd`, AWS `gp3` with provisioned
IOPS/throughput. The policy lives on the sc-inspector side (`benchmark_tiers.db_disk_options`) and is
passed through `sc-runner`'s generic per-VM disk knobs (`disk_type` / `disk_iops` / `disk_throughput`),
so `sc-runner` stays a plain, reusable provisioner with no benchmark-specific defaults. It is applied
**only in the multi-VM DB-benchmark stack** — normal single-VM inspections and the companion client
keep the cheap provider default (Azure `Standard_LRS`, GCP `pd-standard`, AWS AMI-default `gp3`), so
the higher-cost storage is paid for only when the DB benchmark actually runs. All tiers are
env-overridable (`MULTI_VM_DB_DISK_TYPE`, `MULTI_VM_DB_DISK_IOPS`, `MULTI_VM_DB_DISK_THROUGHPUT`) and
can be disabled by setting `MULTI_VM_DB_DISK_TYPE=` (empty) to fall back to the provider default.
Note: disk fsync latency **cannot** be equalized across clouds (network-attached vs local NVMe), which
is exactly why write-heavy headline scores use `async`.

**Companion client:** picked from the catalog as the cheapest x86_64 instance meeting
`stressngfull:best1` score and memory/vCPU requirements (benchmark images are amd64-only). Sized
to ~½ DB vCPUs from multi-VM measurements (F16: ~6.5 cores for both async and durable HammerDB at
16 VUs), with a small bump for parallel schema-build loaders. Client vCPUs never exceed the DB host.

**Profiling ladder (concurrency):** the inspector passes `SC_PROFILE_VUS` to benchmark containers.
Ladder rungs scale geometrically with DB vCPU count (1 → 2 → 4 → … → vCPUs). Workload-specific
caps apply before vCPU/durability limits: HammerDB TPC-C uses warehouse spread (`wh_per_vu_min`: 5
below 16 vCPUs, 20 at 16+); BenchBase uses scale factor ÷ 5 (Wikipedia SF 50 on F16 → up to 10
terminals). For **`async`** (CPU-bound) workloads, extra rungs at **1.5×** and **2×** vCPUs are
added when the workload cap allows (catalog spans 1–1920 vCPUs). For **`durable`** (disk/fsync-bound)
workloads the ladder stops at **min(vCPUs, 16)** with no oversubscription.

**Initial rollout allowlist:** `azure` / `Standard_F16ams_v6` only (`servers_only` on tasks). Expand
by validating multi-VM stacks per vendor and adding `(vendor, instance)` pairs to the allowlist.

**Runtime budget (F16 DB + client):** about 3–4 hours for OLTP (both durability tiers) +
read-heavy + C30; add **~1–2 hours** for TPC-H (parallel `pg_num_tpch_threads` build + query
profiling). Run OLAP on a fresh VM pair when a long prior session OOM-killed the host inspector.

**Artifacts:**

- `<task>/metrics.json` — `score`, `score_unit`, `durability`, `peak_concurrency`, `client_rtt_ms`, `latency_ms` (p50/p95/p99/avg/min/max at peak), `cache_ratio`, `profile` (each ladder rung includes `latency_ms` when available)
- `<task>/meta.json` — standard inspector task lifecycle

Only the **server** VM uploads S3 run-status; cleanup destroys the whole stack (both VMs).
