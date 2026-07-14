# Postgres benchmark methodology (sc-inspector)

This document describes how **Spare Cores** measures managed and self-hosted Postgres performance for the Navigator. Implementation lives in `sc-inspector`, `sc-runner`, `sc-images` (`benchmark-hammerdb-postgres`, `benchmark-benchbase-postgres`, `benchmark-postgres-server`), and published artifacts in `sc-inspector-data`.

## Goals and non-goals

**Goals**

- Produce **comparable headline scores** across cloud SKUs for the same nominal cache tier (C100 / C30).
- Separate **compute-bound** throughput (async durability) from **disk-commit-bound** throughput (durable tier).
- Use industry-standard drivers (HammerDB TPROC-C / TPC-H, BenchBase Wikipedia / YCSB) with adaptive concurrency profiling.
- Record enough metadata in `stdout` JSON that an expert can reconstruct sizing, ladder rungs, RTT, and provision context.

**Non-goals**

- Official audited TPC-C / TPC-H publication (we use HammerDB “TPROC” workloads as proxies).
- Equalizing storage fsync latency across clouds (impossible with network-attached disks); we disclose durable scores separately.
- Application-specific tuning (fixed [GUC](https://www.postgresql.org/docs/current/acronyms.html) template, fixed workload mix, fixed profiling policy).



## Two topologies


| Topology                            | Where data lives                                                    | DB                                                             | Client                                            | Orchestration                                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Multi-VM** (`topology: multi_vm`) | `sc-inspector-data/data/<vendor>/<instance>/`                       | Self-hosted Postgres 18 in Docker on the **DB VM**             | Separate **companion VM** in the same region/zone | DB host runs `postgres_multi.py`; client runs `companion` daemon; benchmarks invoked over multiprocessing connection |
| **DBaaS** (`topology: dbaas`)       | `sc-inspector-data/dbaas/<vendor>/<native_id>/postgres/<ver>/<ha>/` | Vendor managed Postgres (Azure Flexible Server, GCP Cloud SQL) | Companion VM in customer VPC/VNet                 | Client VM runs full `inspect`; connects to managed endpoint over private network                                     |


**Rollout allowlists** (expand deliberately after stack validation):

- Multi-VM: `azure/Standard_F16ams_v6`, `azure/Standard_E16ds_v5`
- DBaaS: `azure/Standard_E16ds_v5/postgres/18/standalone`, `gcp/db-perf-optimized-N-16/postgres/18/standalone`



## Task matrix

Six workload families, each at priority band **1.x** (run before characterization tasks like stress-ng). Tasks within the same priority run sequentially; lower priority number runs first.


| Task suffix                 | Tool      | Workload proxy   | Cache tier       | Durability  | Timeout | Primary metric |
| --------------------------- | --------- | ---------------- | ---------------- | ----------- | ------- | -------------- |
| `…_oltp_mixed_c100`         | HammerDB  | TPROC-C (`tpcc`) | C100 (ratio 1.0) | **async**   | 60 min  | NOPM           |
| `…_oltp_mixed_c30`          | HammerDB  | TPROC-C          | C30 (ratio 0.3)  | **async**   | 120 min | NOPM           |
| `…_oltp_mixed_durable_c100` | HammerDB  | TPROC-C          | C100             | **durable** | 60 min  | NOPM           |
| `…_read_heavy_c100`         | BenchBase | Wikipedia        | C100             | durable     | 60 min  | TPM            |
| `…_crud_simple_c100`        | BenchBase | YCSB             | C100             | **async**   | 60 min  | TPM            |
| `…_olap_c100`               | HammerDB  | TPC-H (`tpch`)   | C100             | durable     | 120 min | QphH           |


Task names are prefixed `hammerdb_postgres_multi_*`, `benchbase_postgres_multi_*` (multi-VM) or `…_dbaas_*` (DBaaS).

**Durability semantics**

- `async` **(headline for writes):** timed phase sets `synchronous_commit=off` on benchmark roles. `fsync` remains **on** — no corruption risk on crash, only loss of the last ~100 ms of commits on an ephemeral VM. Removes per-commit WAL wait so scores reflect CPU/memory/lock scaling, not disk fsync latency.
- `durable`**:** production-default `synchronous_commit=on`. For HammerDB OLTP this is **disk/fsync bound** and ranks the **storage product**, not compute. Stored under the same `benchmark_id` with `durability` field disambiguation. Read-heavy Wikipedia and OLAP TPC-H use durable because reads dominate or workload is read-only.

Azure Flexible Server historically could not relax `synchronous_commit` at the service level; the catalog flag `sync_commit_session_settable` gates async tasks. PoC Azure target is now marked settable and async tasks have been observed to complete.

## Current results (2026-07-14)

Headline score = best concurrency from the profiling ladder (see below). **Peak c** = terminals/VUs at that score.

### Multi-VM — `data/azure/…`


| Instance           | Task                    | Status | Score     | Unit | Peak c | Durability |
| ------------------ | ----------------------- | ------ | --------- | ---- | ------ | ---------- |
| Standard_E16ds_v5  | OLTP mixed C100         | ✓      | 272,455   | NOPM | 16     | async      |
| Standard_E16ds_v5  | OLTP mixed C30          | ✓      | 288,707   | NOPM | 32     | async      |
| Standard_E16ds_v5  | OLTP mixed durable C100 | ✓      | 91,867    | NOPM | 16     | durable    |
| Standard_E16ds_v5  | read-heavy C100         | ✓      | 152,239   | TPM  | 10     | durable    |
| Standard_E16ds_v5  | CRUD C100               | ✓      | 2,107,053 | TPM  | 24     | async      |
| Standard_E16ds_v5  | OLAP C100               | ✗137   | —         | QphH | —      | durable    |
| Standard_F16ams_v6 | OLTP mixed C100         | ✓      | 342,565   | NOPM | 16     | async      |
| Standard_F16ams_v6 | OLTP mixed C30          | ✓      | 326,625   | NOPM | 32     | async      |
| Standard_F16ams_v6 | OLTP mixed durable C100 | ✗137   | —         | NOPM | —      | durable    |
| Standard_F16ams_v6 | read-heavy C100         | ✓      | 308,170   | TPM  | 10     | durable    |
| Standard_F16ams_v6 | CRUD C100               | ✓      | 3,036,505 | TPM  | 32     | async      |
| Standard_F16ams_v6 | OLAP C100               | …      | —         | QphH | —      | durable    |




### DBaaS — `dbaas/azure/Standard_E16ds_v5/postgres/18/standalone`


| Task                    | Status | Score     | Unit | Peak c | Durability |
| ----------------------- | ------ | --------- | ---- | ------ | ---------- |
| OLTP mixed C100         | ✓      | 379,032   | NOPM | 16     | async      |
| OLTP mixed durable C100 | ✓      | 229,294   | NOPM | 16     | durable    |
| read-heavy C100         | ✓      | 213,082   | TPM  | 10     | durable    |
| CRUD C100               | ✓      | 3,253,604 | TPM  | 32     | async      |
| OLAP C100               | ✓      | 137       | QphH | 1      | durable    |


**Not in repo yet:** GCP DBaaS (`db-perf-optimized-N-16`) — bootstrap failure fixed 2026-07-10, retry pending. DBaaS C30 tier not run on Azure.

**Known failure modes:** exit **137** = task timeout (companion kills client container) or OOM; empty stdout usually means killed before benchmark output flushed.

**Expert flags**

- F16ams_v6 beats E16ds_v5 on multi-VM async OLTP and read-heavy where both succeeded.
- DBaaS durable OLTP (~~229k NOPM) ≫ multi-VM durable on same SKU class (~~92k) — managed disk/IOPS tier differs from self-hosted Premium_LRS VM disk.
- DBaaS OLAP **137 QphH @ SF30** is suspiciously low; ladder only reached **c=1** — treat as “completed but needs validation”, not a ranking input.



## End-to-end execution flow



### Multi-VM

1. `inspector start` (or CI) selects a DB instance from the allowlist with pending tasks.
2. `lib._try_start_multi_vm_inspect` provisions a **single Pulumi stack** with two VMs (`sc-runner/resources/multi_vm.py`): DB host + companion client.
3. **DB VM user-data** clones `sc-inspector-data`, starts Postgres 18 (`benchmark-postgres-server` image) with workload-specific GUCs, waits for companion TCP connection.
4. **Client VM user-data** starts `inspector companion` (multiprocessing listener on port 18765, authkey in env).
5. For each task in priority order, DB host `postgres_multi.run_multi_vm_task`:
  - Starts/resets workload DB (`bench`, `benchbase`, `tpcc`, `tpch`).
  - Sends `RunBenchmark` to companion with Docker image + env (including `SC_PROFILE_VUS`).
  - Companion pulls image and runs benchmark container with `network_mode: host` targeting DB private IP.
6. After priority band 1 completes, companion is **powered off** (`finalize_multi_vm`) to save cost.
7. Artifacts pushed to git under `data/<vendor>/<db_instance>/<task>/`; S3 run record from DB VM only.



### DBaaS

1. Manual workflow `start-dbaas.yml` → `inspector start-dbaas --vendor …`.
2. One managed DB + client VM per **cache tier** per invocation (`dbaas_start.py` groups tasks by `cache_tier`; C100 and C30 are separate provisions).
3. Client VM runs `inspect --dbaas-instance-key …` with `TOPOLOGY=dbaas`.
4. `postgres_dbaas.wait_db_ready`: wait for TCP, bootstrap `scadmin` + `bench` database (GCP: create role as `postgres`, create DB as `scadmin`).
5. Benchmark containers run **on the client VM** (no multiprocessing hop), `network_mode: host`, SSL mode from `SC_PROVISION_NETWORK_MODE`.
6. Artifacts under `dbaas/…`; cleanup destroys stack when S3 run record reports termination.



## Cache tiers (C100 / C30)

Cache tier encodes **how much of the DB RAM we pretend is available for the working set** — not a provider “cache” SKU.


| Tier     | `cache_ratio` | Meaning                                                                                          |
| -------- | ------------- | ------------------------------------------------------------------------------------------------ |
| **C100** | 1.0           | Schema sized to ~25% of DB RAM (`BUFFER_FRAC = 0.25`) — “fits in memory” headline                |
| **C30**  | 0.3           | Same formula with ratio 0.3 → **larger** schema budget (~3.3×), stressing buffer cache miss path |


Core sizing (`benchmark_tiers.py`):

```
schema_gib   = BUFFER_FRAC * mem_gib / cache_ratio     # 0.25 * RAM / ratio
disk_gib     = schema_gib * DISK_SCHEMA_RATIO          # × 2.0 headroom for WAL + build
```

**Feasibility** checks before a task runs: schema ≥ 0.5 GiB, disk fits `provisioned_gib * 0.85`, memory headroom for connections (`run_vus * 0.05 GiB + OS_HEADROOM`), warehouse/scale-factor minimums.

**DBaaS:** each cache tier is a **separate managed instance** (different `storage_gib` / IOPS). **Multi-VM:** one disk size covers all tiers on that instance (max over planned tasks).

## Workload sizing



### HammerDB TPROC-C (OLTP mixed)

- **Warehouses:** `max(wh_per_vu_min, int(schema_gib / 0.095 GiB))`, cap 100,000.
- `wh_per_vu_min`**:** 5 below 16 vCPUs, **20 at 16+ vCPUs** (reduces warehouse sprawl on large hosts).
- **Build VUs:** `min(db_vcpus, warehouses, 64)` — parallel `buildschema` loaders.
- **Timed run:** HammerDB `pg_driver=timed`, default **1 min ramp + 2 min measure** (`SC_RAMPUP_MIN`, `SC_DURATION_MIN`), stored procs enabled.
- **Score:** HammerDB-reported **NOPM** (New-Order transactions per minute); also TPM in output.

Example **F16ams_v6 C100** (128 GiB): schema ≈ 32 GiB → ~337 warehouses; provisioned disk ≈ 251 GiB.

### HammerDB TPC-H (OLAP)

- **Scale factor:** largest value in `{1, 10, 30, 100, …}` with `SF * 1 GiB ≤ schema_gib` → **SF30** on 128 GiB C100.
- **Build:** `pg_num_tpch_threads = build_vus` (parallel schema build — critical for 120 min timeout).
- **Run:** `pg_total_querysets 1`, `pg_degree_of_parallel = min(db_vcpus, 16)`, query phase (not timed driver).
- **Score:** **QphH** (queries per hour @ scale); profiling ladder often collapses to low concurrency for long-running queries.



### BenchBase Wikipedia (read-heavy)

- **Scale factor:** `max(10, min(200, int(mem_gib / 2.5)))` → **51** on 128 GiB.
- **Durability:** durable (`synchronous_commit=on`).
- **Run length:** 90 s per ladder rung, 120 s confirmation at peak.
- **Score:** **TPM** = measured TPS × 60.



### BenchBase YCSB (CRUD simple)

- **Scale factor:** `max(100, min(500_000, int(schema_gib * 1024)))` rows (≈1 KiB/row).
- **Durability:** async (`synchronous_commit=off` for headline).
- **Score:** TPM.



## Storage provisioning



### Multi-VM DB disk (`benchmark_tiers.db_disk_options` → `sc-runner` VM knobs)

Write-heavy **durable** scores depend on disk fsync latency, so the **DB host** gets upgraded SSD (client keeps cheap default disk):


| Vendor | Default DB disk | Notes                                              |
| ------ | --------------- | -------------------------------------------------- |
| Azure  | `Premium_LRS`   | Optional `PremiumV2_LRS` + IOPS/throughput via env |
| GCP    | `pd-ssd`        |                                                    |
| AWS    | `gp3`           | 16k IOPS, 1000 MB/s provisioned                    |


Overrides: `MULTI_VM_DB_DISK_TYPE`, `MULTI_VM_DB_DISK_IOPS`, `MULTI_VM_DB_DISK_THROUGHPUT`. Empty `MULTI_VM_DB_DISK_TYPE` → provider default.

**Disk size:** `effective_disk_gib(vendor, server, max_task_disk_need)` = `max(128, ceil(required / 0.85))` (`disk.py`). Required = max over all multi-VM tasks on that instance.

### DBaaS storage (`dbaas_tiers.provision_spec`)

```
storage_gib = max(mem_gib, ceil(schema_gib * 2 / 0.85))
```

**Azure Flexible Server:** `PremiumV2_LRS` + P-tier IOPS mapping; minimum tier **P40** for C100, **P20** for C30 (so durable headline is not capped by P30 baseline). **GCP Cloud SQL:** `PD_SSD`, size-driven IOPS (no P-tier knob).

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

Observed companions: **Standard_F8ams_v6** (F16 stack), **Standard_D8als_v6** / **D8ls_v6** (E16 DBaaS).

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
| TPC-H           | `scale_factor // 5`                        | Long queries                               |


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


| Image                          | Workloads          | Output                                                                                |
| ------------------------------ | ------------------ | ------------------------------------------------------------------------------------- |
| `benchmark-hammerdb-postgres`  | TPROC-C, TPC-H     | JSON to stdout: `score`, `score_unit`, `profile[]`, `latency_ms`, `hammerdb{}` params |
| `benchmark-benchbase-postgres` | Wikipedia, YCSB    | JSON: `score` (TPM), `profile[]` with per-rung latency                                |
| `benchmark-postgres-server`    | (multi-VM DB only) | Postgres 18 server                                                                    |


**Stored metrics** (crawler): `hammerdb_postgres_multi:nopm`, `benchbase_postgres_multi:tpm`, with `durability`, `cache_tier`, `topology`, `peak_concurrency`, `client_rtt_ms` in config JSON.

**RTT:** measured once per run (`pg_rtt_ms`): opens one connection, runs warmup `SELECT 1`s, then reports the **minimum** of 20 timed `SELECT 1` round-trips on that warm session (connect/auth excluded). Typically **0.15–0.5 ms** on private VNet/VPC — not the bottleneck.

## stdout JSON fields

Each successful benchmark writes **one JSON object** to `<task>/stdout` (also mirrored as `/output/metrics.json` inside the container). Fields below are stable across topologies unless noted.

### Common top-level fields


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `benchmark` | string | Driver image id: `hammerdb_postgres` or `benchbase_postgres`. |
| `workload` | string | Proxy workload: `tpcc`, `tpch`, `wikipedia`, or `ycsb`. |
| `topology` | string | `multi_vm` (self-hosted Postgres on DB VM) or `dbaas` (managed endpoint). |
| `cache_ratio` | number | Cache tier ratio from task def: `1.0` (C100) or `0.3` (C30). |
| `durability` | string | Task durability: `async` or `durable` (see **Durability semantics** above). |
| `client_rtt_ms` | number | Min `SELECT 1` round-trip (ms) on an **already-established** session: one `psycopg.connect`, 3 warmup queries, then min of 20 timed `SELECT 1` samples (`SC_RTT_WARMUP` / `SC_RTT_SAMPLES`). TCP handshake and Postgres auth are **not** included in the reported value. |
| `peak_concurrency` | integer | Client terminals / HammerDB VUs at the winning ladder rung. |
| `score` | integer | **Headline throughput** (see scoring rules below). |
| `score_unit` | string | Unit for `score`: `NOPM`, `QphH`, or `tpm`. |
| `profile` | array | Per-rung profiling results (see below). |
| `synchronous_commit` | object | `SHOW synchronous_commit` captured per relevant DB session (see below). |

### Headline scoring rules


| Driver | Workloads | `score` meaning | Extra top-level fields |
| ------ | --------- | --------------- | ---------------------- |
| HammerDB | `tpcc` | **NOPM** — new-order transactions/min at peak concurrency ([HammerDB NOPM](https://www.hammerdb.com/blog/uncategorized/how-to-understand-tpc-c-tpmc-and-tproc-c-nopm-and-what-is-good-performance/)). | `score_tpm` (all TPROC-C tx/min), `warehouses` |
| HammerDB | `tpch` | **QphH** — queries per hour @ scale (parsed from HammerDB output or derived from geometric mean). | `scale_factor`, `score_tpm` is always `0` |
| BenchBase | `wikipedia`, `ycsb` | **TPM** — transactions per minute (`TPS × 60` from BenchBase summary). | `scalefactor`, optional top-level `latency_ms` from confirmation run |

**HammerDB OLTP:** `score` = max NOPM across profiling rungs **and** confirmation repeat(s) at `peak_concurrency` (confirmation can be lower; headline keeps the best observed sample).

**BenchBase:** `profile[]` uses 90 s rungs to pick `peak_concurrency`; `score` comes from a separate **120 s confirmation** run at that concurrency only.

### `profile[]` entries

Each element is one profiling rung (plus optional confirmation).


| Field | Present | Type | Meaning |
| ----- | ------- | ---- | ------- |
| `concurrency` | always | integer | Terminals (BenchBase) or VUs (HammerDB) for this rung. |
| `score` | always | integer | Throughput at this rung (same unit as headline). |
| `tpm` | HammerDB OLTP | integer | Total PostgreSQL TPM at this rung (all TPROC-C transaction types). |
| `tps` | BenchBase | number | BenchBase requests/second at this rung. |
| `latency_ms` | optional | object | Transaction latency ms: `p50`, `p95`, `p99`, `avg`, `min`, `max`. HammerDB: weighted from job timing JSON (OLTP). BenchBase: from summary latency distribution. |
| `confirmation` | optional | boolean | `true` on HammerDB confirmation repeat(s) at `peak_concurrency` (absent on ladder rungs). |

### `synchronous_commit` object

Recorded after schema build, before the timed/query phase.


| Field | Type | Meaning |
| ----- | ---- | ------- |
| `sessions` | array | `{user, database, synchronous_commit}` for each checked role. |
| `benchmark_session` | object | The session HammerDB/BenchBase actually uses (`on` or `off`). |

Async OLTP/YCSB expect `off` on the benchmark session; durable tasks expect `on`.

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
| `cache_tier` | string | `c100` or `c30`. |
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
| `wh_per_vu_min` | all | Minimum warehouses (OLTP) or scale units per VU cap. |
| `storedprocs` | OLTP | Always `true` (PostgreSQL stored procedures). |
| `driver` | OLTP | `timed` for TPROC-C; OLAP uses query driver (not timed). |
| `warehouses` | OLTP | TPC-C warehouse count. |
| `scale_factor` | OLAP | TPC-H scale factor (SF). |
| `benchmark_user` | all | HammerDB schema user (`tpcc` or `tpch`). |
| `degree_of_parallel` | OLAP | `pg_degree_of_parallel` for TPC-H query phase. |

HammerDB OLTP also sets top-level `warehouses`; OLAP sets top-level `scale_factor`. Optional top-level `latency_ms` (OLTP) reflects the latency sample at the winning `score`.

### BenchBase-only fields

- `scalefactor` — BenchBase scale factor (Wikipedia row count proxy / YCSB row count).
- `profile[].tps` — requests per second at each rung.
- Top-level `latency_ms` — from the 120 s confirmation run (not the max across profile rungs).

`warehouses` appears only if a BenchBase `tpcc` workload were run (not in current task matrix).

### Example snippets

HammerDB OLTP (multi-VM): `score` / `score_tpm` / `score_unit: "NOPM"` / `profile[].tpm` — see `data/azure/Standard_E16ds_v5/hammerdb_postgres_multi_oltp_mixed_c100/stdout`.

BenchBase read-heavy: `score_unit: "tpm"` / `profile[].tps` / `latency_ms` — see `data/azure/Standard_E16ds_v5/benchbase_postgres_multi_read_heavy_c100/stdout`.

DBaaS HammerDB: provision fields + `db_fqdn` — see `dbaas/azure/Standard_E16ds_v5/postgres/18/standalone/hammerdb_postgres_dbaas_oltp_mixed_c100/stdout`.

## Artifacts and operations


| Path                | Contents                                                                                 |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `<task>/stdout`     | **Single JSON** — scores, profile, provision metadata (DBaaS), HammerDB/BenchBase params |
| `<task>/meta.json`  | Inspector lifecycle: start/end, exit_code, task_hash, kernel                             |
| `timing/<run_id>/`  | Wall-clock markers                                                                       |
| S3 `runs/inspect/…` | Termination record for cleanup                                                           |


**Workflows:** multi-VM via normal `inspector start` + `cleanup`; DBaaS via `start-dbaas.yml` + `cleanup-dbaas`. Failed inspect uploads S3 log; cleanup destroys Pulumi stack when `terminated_at` appears.

**Runtime budget (16 vCPU class):** ~3–4 h for OLTP + read-heavy + C30; add ~1–2 h for TPC-H (parallel build + query profiling). OLAP should run on a **fresh** VM pair after long sessions (host OOM risk).

## Code map (quick reference)


| Concern                              | Location                                                     |
| ------------------------------------ | ------------------------------------------------------------ |
| Task definitions (multi-VM)          | `sc-inspector/inspector/tasks.py`                            |
| Task definitions (DBaaS)             | `sc-inspector/inspector/dbaas_tasks.py`                      |
| Cache tier math, ladder, disk policy | `sc-inspector/inspector/benchmark_tiers.py`                  |
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




## Discussion prompts

1. **Async vs durable split** — Is `synchronous_commit=off` with `fsync=on` an acceptable headline for cross-cloud compute ranking, with durable disclosed separately?
2. **Warehouse / SF sizing** — C100 uses 25% of RAM for schema; C30 forces ~3.3× larger working set. Are HammerDB warehouse count and BenchBase SF formulas reasonable vs TPC council guidance?
3. **Profiling ladder** — Geometric doubling + async 2× oversubscribe vs fixed-duration industry practice (e.g. 15–30 min runs at fixed terminals).
4. **HammerDB TPROC vs audited TPC** — Stored procedures on, 2 min measure window, NOPM as metric.
5. **TPC-H SF30 on 128 GiB** — ~30 GiB data; parallel build threads vs query `degree_of_parallel`; QphH parsing across HammerDB versions.
6. **Multi-VM vs DBaaS** — Same nominal 16 vCPU / 128 GiB but different storage stacks (self-hosted Premium_LRS VM disk vs Flexible Server PremiumV2 P40). Durable NOPM gap (92k vs 229k) is expected but needs disclosure.
7. **Companion sizing** — ½ DB vCPUs driver VM; is stress-ng `best1` a sensible proxy for “good enough” client CPU?
8. **Azure async on Flexible Server** — Session-level `synchronous_commit=off` now works on PoC SKU; confirm against Microsoft constraints for other tiers.

