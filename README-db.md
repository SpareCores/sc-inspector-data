# Postgres benchmark methodology (sc-inspector)

This document describes how **Spare Cores** measures managed and self-hosted Postgres performance for the Navigator. Implementation lives in `sc-inspector`, `sc-runner`, `sc-images` (`benchmark-hammerdb-postgres`, `benchmark-benchbase-postgres`, `benchmark-postgres-server`), and published artifacts in `sc-inspector-data`.

## Goals and non-goals

**Goals**

- Produce **comparable headline scores** across cloud SKUs using **fixed shirt-size tiers** (S / M / L) with identical workloads for every instance in a tier.
- Separate **compute-bound** throughput (async durability) from **disk-commit-bound** throughput (durable — DBaaS only).
- Use industry-standard drivers (HammerDB TPROC-C, BenchBase Wikipedia / YCSB) with adaptive concurrency profiling.
- Record enough metadata in `stdout` JSON that an expert can reconstruct sizing, ladder rungs, RTT, and provision context.

**Non-goals**

- Official audited TPC-C publication (we use HammerDB "TPROC" workloads as proxies).
- Equalizing storage fsync latency across clouds (impossible with network-attached disks); DBaaS durable scores are disclosed separately.
- Application-specific tuning (fixed [GUC](https://www.postgresql.org/docs/current/acronyms.html) template, fixed workload mix, fixed profiling policy).



## Two topologies


| Topology                            | Where data lives                                                    | DB                                                             | Client                                            | Orchestration                                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Multi-VM** (`topology: multi_vm`) | `sc-inspector-data/data/<vendor>/<instance>/`                       | Self-hosted Postgres 18 in Docker on the **DB VM**             | Separate **companion VM** in the same region/zone | DB host runs `postgres_multi.py`; client runs `companion` daemon; benchmarks invoked over multiprocessing connection |
| **DBaaS** (`topology: dbaas`)       | `sc-inspector-data/dbaas/<vendor>/<native_id>/postgres/<ver>/<ha>/` | Vendor managed Postgres (Azure Flexible Server, GCP Cloud SQL) | Companion VM in customer VPC/VNet                 | Client VM runs full `inspect`; connects to managed endpoint over private network                                     |


**Rollout allowlists** (expand deliberately after stack validation):

- Multi-VM: `azure/Standard_F16ams_v6`, `azure/Standard_E16ds_v5`
- DBaaS: `azure/Standard_E16ds_v5/postgres/18/standalone`, `gcp/db-perf-optimized-N-16/postgres/18/standalone`



## Fixed shirt-size tiers (S / M / L)

All benchmark workloads use **fixed, absolute sizing** per tier. Every instance that qualifies for a tier runs the **exact same** warehouse count / scale factor, so scores are directly comparable across instance sizes and clouds.


| Tier | HammerDB WH | Schema (GiB) | RAM range (GiB)   | BenchBase Wikipedia SF | BenchBase YCSB SF |
| ---- | ----------- | ------------ | ------------------ | ---------------------- | ----------------- |
| **S** | 100         | ~10          | 16 – 128           | 20                     | 5,000             |
| **M** | 300         | ~29          | 32 – 512           | 50                     | 20,000            |
| **L** | 1000        | ~95          | 128 – ∞            | 100                    | 50,000            |


Instances run **every tier** where their RAM falls within `[min_ram_gib, max_ram_gib]`. Most instances run 1–2 tiers; large instances run all 3. The overlapping ranges ensure continuous comparability chains: a 64 GiB instance runs both S and M, so its S score is comparable to smaller instances and its M score to larger ones.

**Feasibility** check: `shirt_size_feasible(size, mem_gib)` gates each task before scheduling.


## Task matrix

Three workload families × three shirt sizes, at priority band **1.x** (run before characterization tasks like stress-ng). Tasks within the same priority run sequentially; lower priority number runs first.

### Multi-VM tasks (async durability only)

Multi-VM tasks use **async** durability (`synchronous_commit=off`) exclusively: scores reflect CPU/memory/lock scaling, not the provisioned disk's fsync latency (which is identical across many VM SKUs on the same cloud).


| Task suffix                  | Tool      | Workload proxy | Shirt size | Durability | Timeout | Primary metric |
| ---------------------------- | --------- | -------------- | ---------- | ---------- | ------- | -------------- |
| `…_oltp_mixed_s`             | HammerDB  | TPROC-C        | S          | async      | 60 min  | NOPM           |
| `…_read_heavy_s`             | BenchBase | Wikipedia      | S          | durable    | 60 min  | TPM            |
| `…_crud_simple_s`            | BenchBase | YCSB           | S          | async      | 60 min  | TPM            |
| `…_oltp_mixed_m`             | HammerDB  | TPROC-C        | M          | async      | 60 min  | NOPM           |
| `…_read_heavy_m`             | BenchBase | Wikipedia      | M          | durable    | 60 min  | TPM            |
| `…_crud_simple_m`            | BenchBase | YCSB           | M          | async      | 60 min  | TPM            |
| `…_oltp_mixed_l`             | HammerDB  | TPROC-C        | L          | async      | 120 min | NOPM           |
| `…_read_heavy_l`             | BenchBase | Wikipedia      | L          | durable    | 60 min  | TPM            |
| `…_crud_simple_l`            | BenchBase | YCSB           | L          | async      | 60 min  | TPM            |


Task names are prefixed `hammerdb_postgres_multi_*` or `benchbase_postgres_multi_*`.

### DBaaS tasks (async + durable)

DBaaS retains **both** async and durable durability modes: storage is a bundled, differentiating factor of managed DB offerings, so fsync-bound scores are meaningful for customers comparing DBaaS SKUs.


| Task suffix                  | Tool      | Workload proxy | Shirt size | Durability | Timeout | Primary metric |
| ---------------------------- | --------- | -------------- | ---------- | ---------- | ------- | -------------- |
| `…_oltp_mixed_s_async`       | HammerDB  | TPROC-C        | S          | async      | 60 min  | NOPM           |
| `…_oltp_mixed_s_durable`     | HammerDB  | TPROC-C        | S          | durable    | 60 min  | NOPM           |
| `…_read_heavy_s`             | BenchBase | Wikipedia      | S          | durable    | 60 min  | TPM            |
| `…_crud_simple_s`            | BenchBase | YCSB           | S          | async      | 60 min  | TPM            |
| `…_oltp_mixed_m_async`       | HammerDB  | TPROC-C        | M          | async      | 60 min  | NOPM           |
| `…_oltp_mixed_m_durable`     | HammerDB  | TPROC-C        | M          | durable    | 60 min  | NOPM           |
| `…_read_heavy_m`             | BenchBase | Wikipedia      | M          | durable    | 60 min  | TPM            |
| `…_crud_simple_m`            | BenchBase | YCSB           | M          | async      | 60 min  | TPM            |
| `…_oltp_mixed_l_async`       | HammerDB  | TPROC-C        | L          | async      | 120 min | NOPM           |
| `…_oltp_mixed_l_durable`     | HammerDB  | TPROC-C        | L          | durable    | 120 min | NOPM           |
| `…_read_heavy_l`             | BenchBase | Wikipedia      | L          | durable    | 60 min  | TPM            |
| `…_crud_simple_l`            | BenchBase | YCSB           | L          | async      | 60 min  | TPM            |


Task names are prefixed `hammerdb_postgres_dbaas_*` or `benchbase_postgres_dbaas_*`.

**Durability semantics**

- `async` **(headline for writes):** timed phase sets `synchronous_commit=off` on benchmark roles. `fsync` remains **on** — no corruption risk on crash, only loss of the last ~100 ms of commits on an ephemeral VM. Removes per-commit WAL wait so scores reflect CPU/memory/lock scaling, not disk fsync latency.
- `durable`**(DBaaS only for OLTP):** production-default `synchronous_commit=on`. Ranks the **storage product** bundled with the managed DB. Read-heavy Wikipedia uses durable because reads dominate.

Azure Flexible Server historically could not relax `synchronous_commit` at the service level; the catalog flag `sync_commit_session_settable` gates async tasks. PoC Azure target is now marked settable and async tasks have been observed to complete.



## End-to-end execution flow



### Multi-VM

1. `inspector start` (or CI) selects a DB instance from the allowlist with pending tasks.
2. `lib._try_start_multi_vm_inspect` provisions a **single Pulumi stack** with two VMs (`sc-runner/resources/multi_vm.py`): DB host + companion client.
3. **DB VM user-data** clones `sc-inspector-data`, starts Postgres 18 (`benchmark-postgres-server` image) with workload-specific GUCs, waits for companion TCP connection.
4. **Client VM user-data** starts `inspector companion` (multiprocessing listener on port 18765, authkey in env).
5. For each task in priority order, DB host `postgres_multi.run_multi_vm_task`:
  - Starts/resets workload DB (`bench`, `benchbase`, `tpcc`).
  - Sends `RunBenchmark` to companion with Docker image + env (including `SC_PROFILE_VUS`).
  - Companion pulls image and runs benchmark container with `network_mode: host` targeting DB private IP.
6. After priority band 1 completes, companion is **powered off** (`finalize_multi_vm`) to save cost.
7. Artifacts pushed to git under `data/<vendor>/<db_instance>/<task>/`; S3 run record from DB VM only.



### DBaaS

1. Manual workflow `start-dbaas.yml` → `inspector start-dbaas --vendor …`.
2. One managed DB + client VM per **shirt size** per invocation (`dbaas_start.py` groups tasks by `shirt_size`).
3. Client VM runs `inspect --dbaas-instance-key …` with `TOPOLOGY=dbaas`.
4. `postgres_dbaas.wait_db_ready`: wait for TCP, bootstrap `scadmin` + `bench` database (GCP: create role as `postgres`, create DB as `scadmin`).
5. Benchmark containers run **on the client VM** (no multiprocessing hop), `network_mode: host`, SSL mode from `SC_PROVISION_NETWORK_MODE`.
6. Artifacts under `dbaas/…`; cleanup destroys stack when S3 run record reports termination.



## Workload sizing



### HammerDB TPROC-C (OLTP mixed)

- **Warehouses:** fixed per shirt size — S=100, M=300, L=1000.
- `wh_per_vu_min`**:** 5 below 16 vCPUs, **20 at 16+ vCPUs** (reduces VU sprawl on large hosts).
- **Build VUs:** `min(db_vcpus, warehouses, 64)` — parallel `buildschema` loaders.
- **Timed run:** HammerDB `pg_driver=timed`, default **1 min ramp + 2 min measure** (`SC_RAMPUP_MIN`, `SC_DURATION_MIN`), stored procs enabled.
- **Score:** HammerDB-reported **NOPM** (New-Order transactions per minute); also TPM in output.



### BenchBase Wikipedia (read-heavy)

- **Scale factor:** fixed per shirt size — S=20, M=50, L=100.
- **Durability:** durable (`synchronous_commit=on`) — reads dominate.
- **Run length:** 90 s per ladder rung, 120 s confirmation at peak.
- **Score:** **TPM** = measured TPS × 60.



### BenchBase YCSB (CRUD simple)

- **Scale factor:** fixed per shirt size — S=5,000, M=20,000, L=50,000 rows (≈1 KiB/row).
- **Durability:** async (`synchronous_commit=off` for headline).
- **Score:** TPM.



## Storage provisioning



### Multi-VM DB disk (`benchmark_tiers.db_disk_options` → `sc-runner` VM knobs)

The **DB host** gets upgraded SSD (client keeps cheap default disk):


| Vendor | Default DB disk | Notes                                              |
| ------ | --------------- | -------------------------------------------------- |
| Azure  | `Premium_LRS`   | Optional `PremiumV2_LRS` + IOPS/throughput via env |
| GCP    | `pd-ssd`        |                                                    |
| AWS    | `gp3`           | 16k IOPS, 1000 MB/s provisioned                    |


Overrides: `MULTI_VM_DB_DISK_TYPE`, `MULTI_VM_DB_DISK_IOPS`, `MULTI_VM_DB_DISK_THROUGHPUT`. Empty `MULTI_VM_DB_DISK_TYPE` → provider default.

**Disk size:** `effective_disk_gib(vendor, server, max_task_disk_need)` = `max(128, ceil(required / 0.85))` (`disk.py`). Required = max over all multi-VM tasks on that instance.

### DBaaS storage (`dbaas_tiers.provision_spec`)

```
storage_gib = ceil(schema_gib * 2 / 0.85)
```

**Azure Flexible Server:** `PremiumV2_LRS` + P-tier IOPS mapping; minimum tier **P40** for L, **P30** for M, **P20** for S. **GCP Cloud SQL:** `PD_SSD`, size-driven IOPS (no P-tier knob).

## Companion client selection (`companion_picker.py`)

Benchmark images are **amd64-only**. For each DB region/zone candidate:

1. Filter catalog: ACTIVE, ONDEMAND, no GPU, **x86_64**, `vcpus ≥ min_vcpus`, `memory ≥ 2 GiB`, price row in that location.
2. Rank by `stressngfull:best1` benchmark score (desc), then **price** (asc), then api_reference.
3. Pick top server.

**Minimum vCPUs** (`benchmark_tiers.companion_client_vcpus`):

```
floor = max(4, (db_vcpus + 1) // 2)     # ~½ DB cores (F16: ~8 for 16 vCPU DB)
build = (build_vus + 3) // 4
min_vcpus = min(db_vcpus, max(floor, build))
```

Rationale: multi-VM measurements on F16 showed ~6.5 client cores saturated HammerDB at 16 VUs for both async and durable; ½ DB vCPUs plus build-loader headroom is the policy. Client vCPUs **never exceed** DB vCPUs.

## Profiling ladder (concurrency)

The inspector sets `SC_PROFILE=1` and passes explicit rungs in `SC_PROFILE_VUS` (comma-separated). Each rung executes a full benchmark; **headline score = max score across rungs**, with a **confirmation repeat** at the peak.

**Base rungs** (`_vcpu_ladder_rungs`): geometric doubling 1, 2, 4, … up to **DB vCPU count**.

**Async-only extras:** 1.5× and 2× vCPU rungs when warehouse/scale-factor caps allow (finds CPU headroom when DB is not fsync-bound).

**Caps**


| Mode            | VU cap                                     | Rationale                                  |
| --------------- | ------------------------------------------ | ------------------------------------------ |
| Async OLTP/YCSB | `min(2 × vcpus, warehouses/wh_per_vu_min)` | CPU-bound; oversubscribe to find peak      |
| Durable OLTP    | `min(vcpus, 16, warehouses/wh_per_vu_min)` | Extra VUs queue on fsync — waste wall time |
| BenchBase       | `scalefactor // 5`                         | Terminals vs data volume                   |


Rungs above the cap are **clamped** to the cap (ladder always includes the ceiling).

## Postgres configuration (multi-VM only)

Self-hosted Postgres GUCs (`postgres_multi.pg_gucs`) per task:

- `shared_buffers` ≈ min(25% RAM, 105% of warehouse schema size)
- `effective_cache_size` ≈ 75% RAM (capped relative to shared_buffers)
- `max_parallel_workers` = vCPUs (cap 128), `max_parallel_workers_per_gather = 2`
- `synchronous_commit` = `off` (async tasks) or `on` (durable)
- `random_page_cost=1.1`, `effective_io_concurrency=128`, WAL sizing tuned for SSD

**DBaaS:** vendor-managed GUC surface; we set session/role `synchronous_commit` where allowed (`postgres_dbaas._apply_durability`). GCP workload roles need `GRANT … WITH ADMIN OPTION` before `SET ROLE` for HammerDB schema users.

## Benchmark containers and scoring


| Image                          | Workloads       | Output                                                                                |
| ------------------------------ | --------------- | ------------------------------------------------------------------------------------- |
| `benchmark-hammerdb-postgres`  | TPROC-C         | JSON to stdout: `score`, `score_unit`, `profile[]`, `latency_ms`, `hammerdb{}` params |
| `benchmark-benchbase-postgres` | Wikipedia, YCSB | JSON: `score` (TPM), `profile[]` with per-rung latency                                |
| `benchmark-postgres-server`    | (multi-VM only) | Postgres 18 server                                                                    |


**Stored metrics** (crawler): `hammerdb_postgres_multi:nopm`, `benchbase_postgres_multi:tpm`, with `durability`, `shirt_size`, `topology`, `peak_concurrency`, `client_rtt_ms` in config JSON.

**RTT:** measured once per run (`pg_rtt_ms`): opens one connection, runs warmup `SELECT 1`s, then reports the **minimum** of 20 timed `SELECT 1` round-trips on that warm session (connect/auth excluded). Typically **0.15–0.5 ms** on private VNet/VPC — not the bottleneck.

## stdout JSON fields

Each successful benchmark writes **one JSON object** to `<task>/stdout` (also mirrored as `/output/metrics.json` inside the container). Fields below are stable across topologies unless noted.

### Common top-level fields


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `benchmark` | string | Driver image id: `hammerdb_postgres` or `benchbase_postgres`. |
| `workload` | string | Proxy workload: `tpcc`, `wikipedia`, or `ycsb`. |
| `topology` | string | `multi_vm` (self-hosted Postgres on DB VM) or `dbaas` (managed endpoint). |
| `shirt_size` | string | Tier label: `S`, `M`, or `L`. |
| `durability` | string | Task durability: `async` or `durable` (see **Durability semantics** above). |
| `client_rtt_ms` | number | Min `SELECT 1` round-trip (ms) on an **already-established** session. |
| `peak_concurrency` | integer | Client terminals / HammerDB VUs at the winning ladder rung. |
| `score` | integer | **Headline throughput** (see scoring rules below). |
| `score_unit` | string | Unit for `score`: `NOPM` or `tpm`. |
| `profile` | array | Per-rung profiling results (see below). |
| `synchronous_commit` | object | `SHOW synchronous_commit` captured per relevant DB session (see below). |
| `postgres` | object | Live server snapshot for reproduction (GUCs, extensions, role settings; see below). |
| `db_vcpus` | integer | vCPUs used for DB-side sizing / VU ladder caps. |
| `client_vcpus` | integer | Client VM vCPUs (VU/build concurrency clamp). |
| `db_mem_gib` | number | DB host RAM (GiB) used for warehouse / buffer sizing. |
| `profile_vus` | array | Concurrency ladder requested for this run. |
| `benchmark_image` | string | Benchmark client image ref (inspector merge). |
| `pg_image` | string | Multi-VM only: Postgres server image ref. |

### Headline scoring rules


| Driver | Workloads | `score` meaning | Extra top-level fields |
| ------ | --------- | --------------- | ---------------------- |
| HammerDB | `tpcc` | **NOPM** — new-order transactions/min at peak concurrency. | `score_tpm` (all TPROC-C tx/min), `warehouses` |
| BenchBase | `wikipedia`, `ycsb` | **TPM** — transactions per minute (`TPS × 60` from BenchBase summary). | `scalefactor`, optional top-level `latency_ms` from confirmation run |

**HammerDB OLTP:** `score` = max NOPM across profiling rungs **and** confirmation repeat(s) at `peak_concurrency`.

**BenchBase:** `profile[]` uses 90 s rungs to pick `peak_concurrency`; `score` comes from a separate **120 s confirmation** run at that concurrency only.

### `profile[]` entries

Each element is one profiling rung (plus optional confirmation).


| Field | Present | Type | Meaning |
| ----- | ------- | ---- | ------- |
| `concurrency` | always | integer | Terminals (BenchBase) or VUs (HammerDB) for this rung. |
| `score` | always | integer | Throughput at this rung (same unit as headline). |
| `tpm` | HammerDB OLTP | integer | Total PostgreSQL TPM at this rung (all TPROC-C transaction types). |
| `tps` | BenchBase | number | BenchBase requests/second at this rung. |
| `latency_ms` | optional | object | Transaction latency ms: `p50`, `p95`, `p99`, `avg`, `min`, `max`. |
| `confirmation` | optional | boolean | `true` on HammerDB confirmation repeat(s) at `peak_concurrency`. |

### `synchronous_commit` object

Recorded after schema build, before the timed/query phase.


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `sessions` | array | `{user, database, synchronous_commit}` for each checked role. |
| `benchmark_session` | object | The session HammerDB/BenchBase actually uses (`on` or `off`). |

Async OLTP/YCSB expect `off` on the benchmark session; durable tasks expect `on`.

### `postgres` object

Captured from the **running** server after the timed phase (inspector merge; also emitted by benchmark images into `metrics.json`). Use this to reproduce GUC state on self-hosted Postgres or to record vendor-managed defaults on DBaaS.


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `version` | string | Full `version()` string. |
| `server_version` | string | `SHOW server_version`. |
| `server_version_num` | integer | `SHOW server_version_num`. |
| `in_recovery` | boolean | `pg_is_in_recovery()`. |
| `settings` | object | All `pg_settings` name→`current_setting()` value (SHOW-style, e.g. `4GB`). |
| `nondefault_settings` | object | Settings whose `source != default`, with `setting` (pretty), `source`, `context`, `vartype`, `category`, optional `unit` / `setting_raw` / `pending_restart`. |
| `extensions` | array | `{name, version}` from `pg_extension`. |
| `role_settings` | array | `ALTER ROLE` / DB settings from `pg_db_role_setting` (`role`, `database`, `config[]`). Includes DBaaS durability overrides. |
| `requested_gucs` | object | Multi-VM only: GUC template inspector applied via `postgres -c` at server start. |

### Multi-VM only (`topology: multi_vm`)

Merged from `host_context()` when the DB host exports disk metadata:


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `storage_gib` | integer | Provisioned data disk on the **DB VM** (GiB). |
| `storage_type` | string | Provider disk SKU (e.g. `Premium_LRS`, `pd-ssd`, `gp3`). |
| `disk_iops` | integer | Provisioned IOPS when set (`MULTI_VM_DB_DISK_IOPS`). |
| `disk_throughput_mb_s` | integer | Provisioned throughput MB/s when set. |

### DBaaS only (`topology: dbaas`)

Merged from `provision_context()` when the managed instance is provisioned:


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `shirt_size` | string | `S`, `M`, or `L`. |
| `vendor_id` | string | Cloud vendor (`azure`, `gcp`, …). |
| `native_id` | string | Compute SKU (e.g. `Standard_E16ds_v5`). |
| `engine_version` | string | Postgres major version (`18`). |
| `ha_mode` | string | `standalone` (current rollout). |
| `sku_id` | string | Catalog key (e.g. `Standard_E16ds_v5:MemoryOptimized:18`). |
| `cpu_count` | number | Managed instance vCPUs. |
| `memory_gib` | number | Managed instance RAM (GiB). |
| `storage_gib` | integer | Managed storage size (GiB). |
| `storage_edition` | string | Vendor storage product (e.g. `ManagedDiskV2`, `PD_SSD`). |
| `client_instance` | string | Companion VM SKU used for the benchmark client. |
| `region` | string | Cloud region. |
| `zone` | string | Zone when zonal (empty if regional). |
| `db_fqdn` | string | Private or public DB endpoint hostname. |
| `network_mode` | string | e.g. `private_vnet`. |
| `iops_tier` | string | Azure P-tier when applicable (e.g. `P40`). |
| `sync_commit_session_settable` | boolean | Whether async tasks were allowed on this SKU. |

### HammerDB-only: `hammerdb` object


| Field | Workloads | Meaning |
| ----- | --------- | ------- |
| `build_vus` | all | Parallel schema-build threads/VUs. |
| `run_vus` | all | Initial run-VU hint from sizing (actual peak comes from profiling). |
| `rampup_min` | OLTP | Timed-driver ramp-up minutes (`SC_RAMPUP_MIN`, default 1). |
| `duration_min` | OLTP | Timed-driver measure window minutes (`SC_DURATION_MIN`, default 2). |
| `profile_vus` | all | Concurrency ladder rungs executed (`SC_PROFILE_VUS`). |
| `final_repeats` | all | Confirmation repeats at peak (`SC_FINAL_REPEATS`, default 1). |
| `wh_per_vu_min` | all | Minimum warehouses per VU cap. |
| `storedprocs` | OLTP | Always `true` (PostgreSQL stored procedures). |
| `driver` | OLTP | `timed` for TPROC-C. |
| `warehouses` | OLTP | TPC-C warehouse count (fixed per shirt size). |
| `benchmark_user` | all | HammerDB schema user (`tpcc`). |

HammerDB OLTP also sets top-level `warehouses`. Optional top-level `latency_ms` (OLTP) reflects the latency sample at the winning `score`.

### BenchBase-only fields

- `scalefactor` — BenchBase scale factor (Wikipedia row count proxy / YCSB row count).
- `profile[].tps` — requests per second at each rung.
- Top-level `latency_ms` — from the 120 s confirmation run (not the max across profile rungs).

## Artifacts and operations


| Path                | Contents                                                                                 |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `<task>/stdout`     | **Single JSON** — scores, profile, provision metadata (DBaaS), HammerDB/BenchBase params |
| `<task>/meta.json`  | Inspector lifecycle: start/end, exit_code, task_hash, kernel                             |
| `timing/<run_id>/`  | Wall-clock markers                                                                       |
| S3 `runs/inspect/…` | Termination record for cleanup                                                           |


**Workflows:** multi-VM via normal `inspector start` + `cleanup`; DBaaS via `start-dbaas.yml` + `cleanup-dbaas`. Failed inspect uploads S3 log; cleanup destroys Pulumi stack when `terminated_at` appears.

**Runtime budget (16 vCPU class):** ~1–2 h per shirt size for all 3 workloads (OLTP + read-heavy + CRUD). Total depends on how many tiers an instance qualifies for.

## Current results

Snapshot from published `stdout` JSON in this repo (2026-07-14 – 2026-07-15). Only tasks with `meta.json` `exit_code=0` are included.

### How to compare on Navigator

Spare Cores compares cloud servers **at the same fixed workload size** (shirt-size tier), not by mixing tiers on one machine. This mirrors how Navigator ranks other benchmarks: **raw peak score** as the headline, **score per USD** when priced (not computed here), and secondary efficiency columns where cross-size fairness matters.

| Rule | What it means |
| ---- | ------------- |
| **Same tier, different instances** | Valid comparison. S-tier on `E8ds_v5` vs S-tier on `E16ds_v5` uses identical warehouse/scale-factor sizing. |
| **Same tier, different topology** | Valid when topology is disclosed (multi-VM self-hosted vs DBaaS managed). |
| **S vs M on the same instance** | **Not** a ranking signal. Peak NOPM/TPM is aggregate throughput at the profiler's chosen peak VU; M-tier allows higher concurrency (more warehouses → higher `wh_per_vu_min` cap). |
| **OLTP headline** | Peak NOPM at adaptive concurrency. Also show **NOPM/vCPU** for 8 vs 16 vCPU cross-size, and **@4 VU** when profiling caps differ. |
| **Read / CRUD headline** | Peak TPM at adaptive concurrency, plus TPM/vCPU for cross-size. |
| **DBaaS durable OLTP** | Separate column — disk-commit bound; not comparable to multi-VM async OLTP. |

HammerDB NOPM is `Δ sum(d_next_o_id) / minutes` — total system throughput, not normalized per warehouse. Industry comparisons (Principled Technologies, AWS/Azure SQL blogs) use the same raw NOPM at a stated concurrency; per-vCPU is a secondary efficiency view, not a replacement headline.

### Coverage


| Topology | Instance | vCPU | RAM (GiB) | Completed | Missing / failed |
| -------- | -------- | ---- | --------- | --------- | ---------------- |
| Multi-VM | `azure/Standard_F16ams_v6` | 16 | 128 | 5 / 9 (S+M) | L-tier not run; `crud_simple_m` failed |
| Multi-VM | `azure/Standard_E16ds_v5` | 16 | 128 | 5 / 9 (S+M) | L-tier not run; `crud_simple_m` failed |
| Multi-VM | `azure/Standard_E8ds_v5` | 8 | 64 | 6 / 6 (S+M) | L-tier out of RAM range |
| DBaaS | `azure/Standard_E16ds_v5` | 16 | 128 | 12 / 12 (S+M/L) | — |
| DBaaS | `gcp/db-perf-optimized-N-16` | 16 | 128 | 3 / 12 | HammerDB (bootstrap); L-tier; `crud_simple_m` pending re-run |

### Multi-VM — Tier S (100 WH / SF 20 / YCSB 5k)

Self-hosted Postgres 18, async durability for OLTP and CRUD; durable for read-heavy.


| Instance | vCPU | OLTP peak NOPM | /vCPU | Peak VU | @4 VU NOPM | Read TPM | /vCPU | CRUD TPM | /vCPU |
| -------- | ---- | -------------- | ----- | ------- | ---------- | -------- | ----- | -------- | ----- |
| `Standard_E8ds_v5` | 8 | **256.0k** | 32.0k | 12 | 156.4k | **107.7k** | 13.5k | 1.79M | **223.3k** |
| `Standard_E16ds_v5` | 16 | 168.5k | 10.5k | 5 † | 137.7k | 86.6k | 5.4k | **1.98M** | 123.5k |
| `Standard_F16ams_v6` | 16 | 157.0k | 9.8k | 5 † | 127.6k | 60.7k | 3.8k | 1.72M | 107.6k |


† 16 vCPU instances cap OLTP profiling at 5 VU on S-tier (`100 WH ÷ 20 wh/VU`). `E8ds_v5` reaches 12 VU (`100 ÷ 5`), so its peak NOPM is higher despite fewer cores. At matched 4 VU, all three are within ~15% (128–156k NOPM).

### Multi-VM — Tier M (300 WH / SF 50 / YCSB 20k)


| Instance | vCPU | OLTP peak NOPM | /vCPU | Peak VU | @4 VU NOPM | Read TPM | /vCPU | CRUD TPM | /vCPU |
| -------- | ---- | -------------- | ----- | ------- | ---------- | -------- | ----- | -------- | ----- |
| `Standard_F16ams_v6` | 16 | **319.6k** | 20.0k | 15 | 120.8k | 136.4k | 8.5k | — † | — |
| `Standard_E16ds_v5` | 16 | 246.7k | 15.4k | 8 | **144.6k** | **161.2k** | 10.1k | — † | — |
| `Standard_E8ds_v5` | 8 | 233.6k | **29.2k** | 12 | 143.4k | 110.9k | **13.9k** | **1.60M** | **200.2k** |


† `crud_simple_m` failed on F16ams and E16ds. At 4 VU, E16ds M (145k) ≈ E8ds M (143k) — tier size does not make the DB slower; peak headline reflects concurrency headroom.

### DBaaS — Tier S


| Instance | vCPU | OLTP async | /vCPU | Peak VU | OLTP durable | /vCPU | Read TPM | /vCPU | CRUD TPM | /vCPU |
| -------- | ---- | ---------- | ----- | ------- | ------------ | ----- | -------- | ----- | -------- | ----- |
| `gcp/db-perf-optimized-N-16` | 16 | — | — | — | — | — | 107.4k | 6.7k | **3.64M** | **227.7k** |
| `azure/Standard_E16ds_v5` | 16 | 140.1k | 8.8k | 5 | 62.7k | 3.9k | 68.0k | 4.3k | 2.14M | 133.6k |


GCP partial run (BenchBase only). Azure S-tier OLTP async is profiling-capped at 5 VU; durable OLTP is ~45% of async (disk-commit bound).

### DBaaS — Tier M


| Instance | vCPU | OLTP async | /vCPU | Peak VU | OLTP durable | /vCPU | Read TPM | /vCPU | CRUD TPM | /vCPU |
| -------- | ---- | ---------- | ----- | ------- | ------------ | ----- | -------- | ----- | -------- | ----- |
| `azure/Standard_E16ds_v5` | 16 | **329.8k** | 20.6k | 15 | 235.7k | 14.7k | **257.5k** | 16.1k | **3.80M** | 237.7k |
| `gcp/db-perf-optimized-N-16` | 16 | — | — | — | — | — | 153.7k | 9.6k | — | — |

### DBaaS — Tier L (Azure only)


| Instance | vCPU | OLTP async | /vCPU | Peak VU | OLTP durable | /vCPU | Read TPM | /vCPU | CRUD TPM | /vCPU |
| -------- | ---- | ---------- | ----- | ------- | ------------ | ----- | -------- | ----- | -------- | ----- |
| `azure/Standard_E16ds_v5` | 16 | **352.0k** | 22.0k | 16 | 226.6k | 14.2k | 201.6k | 12.6k | 3.04M | 190.1k |

L-tier OLTP async peaks at 16 VU (vCPU cap). CRUD M > L (3.80M vs 3.04M) likely reflects client saturation at 32 VU, not DB regression.

### Cross-topology — same tier (`Standard_E16ds_v5`, 16 vCPU, 128 GiB)

Compare self-hosted multi-VM vs Azure Flexible Server **at the same shirt size**. RTT included because it affects profiling on S-tier.


| Tier | Workload | Multi-VM | DBaaS | Multi RTT (ms) | DBaaS RTT (ms) |
| ---- | -------- | -------- | ----- | -------------- | -------------- |
| S | OLTP async (NOPM) | 168.5k @ 5 VU | 140.1k @ 5 VU | 0.223 | 0.409 |
| S | Read-heavy (TPM) | 86.6k @ 4 | 68.0k @ 4 | 0.251 | 0.392 |
| S | CRUD (TPM) | 1.98M @ 32 | 2.14M @ 32 | 0.229 | 0.396 |
| M | OLTP async (NOPM) | 246.7k @ 8 VU | **329.8k @ 15 VU** | 0.213 | 0.403 |
| M | Read-heavy (TPM) | 161.2k @ 10 | **257.5k @ 10** | 0.208 | 0.138 |
| M | CRUD (TPM) | — † | **3.80M @ 32** | — | 0.145 |


DBaaS leads at M-tier for OLTP and read-heavy; multi-VM leads S-tier OLTP when normalized per VU (33.7k vs 28.0k NOPM/VU). S-tier DBaaS gap is partly RTT (0.39–0.41 ms vs 0.22–0.25 ms multi-VM).

## Code map (quick reference)


| Concern                              | Location                                                     |
| ------------------------------------ | ------------------------------------------------------------ |
| Task definitions (multi-VM)          | `sc-inspector/inspector/tasks.py`                            |
| Task definitions (DBaaS)             | `sc-inspector/inspector/dbaas_tasks.py`                      |
| Shirt-size tiers, ladder, disk policy| `sc-inspector/inspector/benchmark_tiers.py`                  |
| Companion picker                     | `sc-inspector/inspector/companion_picker.py`                 |
| Multi-VM orchestration               | `sc-inspector/inspector/postgres_multi.py`                   |
| DBaaS orchestration                  | `sc-inspector/inspector/postgres_dbaas.py`                   |
| DBaaS provision sizing               | `sc-inspector/inspector/dbaas_tiers.py`                      |
| Multi-VM Pulumi stack                | `sc-runner/src/sc_runner/resources/multi_vm.py`              |
| Azure DBaaS stack                    | `sc-runner/src/sc_runner/resources/azure_dbaas.py`           |
| GCP DBaaS stack                      | `sc-runner/src/sc_runner/resources/gcp_dbaas.py`             |
| HammerDB wrapper                     | `sc-images/images/benchmark-hammerdb-postgres/benchmark.py`  |
| BenchBase wrapper                    | `sc-images/images/benchmark-benchbase-postgres/benchmark.py` |
| Published results                    | `sc-inspector-data/data/…`, `sc-inspector-data/dbaas/…`      |
