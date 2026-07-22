# Postgres benchmark methodology (sc-inspector)

How **Spare Cores** measures managed and self-hosted Postgres for the Navigator. Implementation: `sc-inspector`, `sc-runner`, `sc-images` (`benchmark-benchbase-postgres`, `benchmark-postgres-server`), artifacts in `sc-inspector-data`.

Calibration and design rationale live in `sc-db-benchmark-tmp/RESULTS.md` (wikipedia duration study, pgtune GUC defaults).

## Goals and non-goals

**Goals**

- Comparable **wikipedia TPM** across SKUs with a **cache-resident** working set scaled to instance RAM.
- Full durability sweep on **both** topologies: **async** (`synchronous_commit=off`) and **durable** (default `on`).
- Fixed concurrency ladder `{1, ncpus/2, ncpus}` with **5-minute** measurement windows.
- Persist enough metadata (all GUCs, profile rungs, provision context, server logs) to reproduce a run.

**Non-goals**

- HammerDB / YCSB in the live path.
- Equalizing storage fsync latency across clouds.
- Application-specific query mix beyond BenchBase wikipedia weights.

## Two topologies

| Topology | Data path | DB | Client | Orchestration |
| -------- | --------- | -- | ------ | ------------- |
| **Multi-VM** (`topology: multi_vm`) | `data/<vendor>/<instance>/` | Postgres 18 in Docker on the **DB VM** | Companion VM, same region/zone | `postgres_multi.py` ↔ companion multiprocessing |
| **DBaaS** (`topology: dbaas`) | `dbaas/<vendor>/<native_id>/postgres/<ver>/<ha>/` | Azure Flexible Server / GCP Cloud SQL | Client VM in customer VPC/VNet | `postgres_dbaas.py` on the client |

**Rollout allowlists** (expand after stack validation):

- Multi-VM: Azure `Standard_F16ams_v6`, `Standard_E16ds_v5`, `Standard_E8ds_v5`; GCP `n2-standard-8`, `n2-highmem-8`, `n2-standard-16`, `n2-highmem-16`, `c2d-highmem-8`
- DBaaS: Azure `Standard_E16ds_v5/postgres/18/standalone`; GCP `db-perf-optimized-N-8`, `db-perf-optimized-N-16`, `db-memory-optimized-N-8` (each `/postgres/18/standalone`)

### GCP comparison matrix

| Axis | Multi-VM (GCE) | DBaaS (Cloud SQL Enterprise Plus) |
| ---- | -------------- | --------------------------------- |
| **A — cores @ fixed RAM** | `n2-highmem-8` (8c/64 GiB) vs `n2-standard-16` (16c/64 GiB) | No fixed-RAM 16c tier; use `db-perf-optimized-N-8` (8c/64 GiB) vs `N-16` (16c/128 GiB) — cores *and* RAM scale |
| **B — RAM @ fixed cores** | `n2-standard-8` (8c/32 GiB) vs `n2-highmem-8` (8c/64 GiB) | `db-perf-optimized-N-8` (8c/64 GiB) vs `db-memory-optimized-N-8` (8c/256 GiB) |
| **C — µarch @ fixed shape** | `n2-highmem-8` (Intel) vs `c2d-highmem-8` (AMD Milan), both 8c/64 GiB | Cloud SQL does not expose host CPU; compare topologies instead: multi-VM highmem-8/16 ↔ DBaaS N-8/N-16 |

## Live workload: BenchBase wikipedia × durability

| Task | Topology | Durability | Metric |
| ---- | -------- | ---------- | ------ |
| `benchbase_postgres_multi_read_heavy_async` | multi-VM | async (`synchronous_commit=off`) | TPM |
| `benchbase_postgres_multi_read_heavy_durable` | multi-VM | durable (`on`) | TPM |
| `benchbase_postgres_dbaas_read_heavy_async` | DBaaS | async | TPM |
| `benchbase_postgres_dbaas_read_heavy_durable` | DBaaS | durable | TPM |

**Durability**

- **async:** removes per-commit WAL wait so scores track CPU/memory/lock scaling. `fsync` stays on (no corruption risk; only loss of the last ~100 ms of commits on crash).
- **durable:** production-default `synchronous_commit=on` (DBaaS: `ALTER ROLE … RESET` so vendor default applies).

DBaaS async is skipped when the managed catalog / runtime precheck reports `sync_commit_session_settable=false`.

## Schema sizing (~¼ RAM, ≤16 GiB)

```
target_schema_gib = min(0.25 × mem_gib, 16)
scalefactor = round(target_schema_gib / 0.14803)   # measured: SF 100 ≈ 14.8 GiB
```

Multi-VM GUCs come from [pgtune.leopard.in.ua](https://pgtune.leopard.in.ua/) form defaults (`web` / SSD / PG18) — same formulas as run4-wikipedia. Targeting ~¼ RAM for schema (capped at 16 GiB) keeps the working set **inside Postgres caches**. On large RAM hosts the cap leaves schema under a larger buffer cache (e.g. 128 GiB → schema 16 GiB, `shared_buffers` ≈ 32 GiB).

Minimum RAM to schedule: **2 GiB**.

## Shared disk plan (multi-VM ↔ DBaaS)

Both topologies use `db_storage.db_storage_plan(vendor, mem_gib)` so size and I/O targets match:

```
storage_gib = max(64, ceil(schema × 2 / 0.85))
```

| Vendor | Disk type | IOPS / throughput | Comparability contract |
| ------ | --------- | ----------------- | ---------------------- |
| **Azure** | `PremiumV2_LRS` (DBaaS: ManagedDiskV2 + P30 tier) | **5000 IOPS / 200 MB/s** (explicit) | Same type + same provisioned IOPS/throughput |
| **GCP** | `pd-ssd` / Cloud SQL `PD_SSD` | size-derived (~30 IOPS/GiB) | **Same `storage_gib`** (IOPS follows size) |
| **AWS** (later) | `gp3` stub | 5000 / 200 | Same as Azure target when rolled out |

Ops overrides: `MULTI_VM_DB_DISK_TYPE`, `MULTI_VM_DB_DISK_IOPS`, `MULTI_VM_DB_DISK_THROUGHPUT`.

**Caveat:** network-attached fsync latency still differs by cloud/product; async scores isolate compute, durable scores include storage commit cost by design.

## Concurrency ladder

Always run concurrency **1**. When `ncpus ≥ 2`, also run **`ncpus/2`** and **`ncpus`**. Examples: 1-CPU → `{1}`; 16-CPU → `{1, 8, 16}`.

Inspector sets `SC_PROFILE=1` and `SC_PROFILE_VUS`. Headline `score` = max TPM across those rungs (each rung is a full timed measurement).

## Timed run length

| Phase | Default | Env |
| ----- | ------- | --- |
| Warmup | **120 s** | `SC_WARMUP_SECONDS` |
| Measurement | **300 s** (5 min) | `SC_RUN_SECONDS` |

### Why 5 min (duration study)

Calibrated on GCP with BenchBase wikipedia: 2 min warmup, measure ∈ {5, 10, 15, 30} min, **n=5 interleaved** trials per duration on `t2d-standard-16`, `t2d-standard-32`, and `e2-highmem-16` (terminals=`nproc`, fresh create+load each trial).

**Mean TPM ± 95% t-CI (CV%)**

| Instance | 5 min | 10 min | 15 min | 30 min |
| -------- | ----- | ------ | ------ | ------ |
| `t2d-standard-16` | 580 228 ± 3 585 (0.50%) | 578 237 ± 3 503 (0.49%) | 576 567 ± 3 560 (0.50%) | 576 145 ± 3 009 (0.42%) |
| `t2d-standard-32` | 690 881 ± 7 723 (0.90%) | 691 927 ± 21 263 (2.48%) | 677 111 ± 30 259 (3.60%) | 686 730 ± 19 205 (2.25%) |
| `e2-highmem-16` | 260 997 ± 7 045 (2.17%) | 261 574 ± 11 845 (3.65%) | 264 425 ± 5 489 (1.67%) | 260 321 ± 12 490 (3.86%) |

**Δ mean % vs 5 min:** all within ~2% (worst −1.99% on `t2d-32` @ 15 min, partly one outlier; 30 min on that host was only −0.60%). CIs overlap.

**Takeaway:** longer measure windows do **not** systematically tighten CV (run-to-run noise dominates over within-run averaging). Prefer **2 min warmup + 5 min measure**, and spend wall-clock budget on more SKUs / concurrency rungs / replicates rather than 10–30 min windows.

## Postgres configuration

### Multi-VM

GUCs from [pgtune.leopard.in.ua](https://pgtune.leopard.in.ua/) (`pgtune_leopard.generate_for_host`): form defaults `dbType=web`, `hdType=ssd`, `dbVersion=18`, `osType=linux`, `dbSize=mid_ram`; only host RAM and CPU count vary. Then set `synchronous_commit` from task durability. Applied via `postgres -c …`. Requested template: `postgres.requested_gucs`; share URL: `pgtune_share_url`; full live dump: `postgres.settings`.

### DBaaS

Vendor-managed GUC surface — no server-side pg_tune. Full `pg_settings` still snapshotted after the run. Role `synchronous_commit` set/reset for the durability task.

## Artifacts and S3

| Path | Contents |
| ---- | -------- |
| `<task>/stdout` | Single JSON: score, `profile[]`, `postgres{}`, sizing, provision |
| `<task>/stderr` | Driver stderr |
| `<task>/meta.json` | Inspector lifecycle |

**S3 only** (uploaded then deleted locally; not committed to git): `resource_tracker.jsonl`, and multi-VM `postgres.log` (Docker Postgres container logs). Both land under the run’s `tasks/<task>/` prefix.

## Code map

| Concern | Location |
| ------- | -------- |
| Multi-VM / DBaaS tasks | `sc-inspector/inspector/tasks.py`, `dbaas_tasks.py` |
| Schema, ladder, run length | `sc-inspector/inspector/benchmark_tiers.py` |
| Host GUC tune (pgtune) | `sc-inspector/inspector/pgtune_leopard.py` |
| Multi-VM orchestration + postgres.log | `sc-inspector/inspector/postgres_multi.py` |
| DBaaS orchestration | `sc-inspector/inspector/postgres_dbaas.py` |
| DBaaS storage sizing | `sc-inspector/inspector/dbaas_tiers.py` |
| Shared disk IOPS/size plan | `sc-inspector/inspector/db_storage.py` |
| BenchBase wrapper | `sc-images/images/benchmark-benchbase-postgres/benchmark.py` |
| Calibration notes | `sc-db-benchmark-tmp/RESULTS.md` |

Historical S/M/L HammerDB+YCSB+wikipedia runs may still exist under `data/` and `dbaas/`; they are **not** produced by the current live task matrix.
