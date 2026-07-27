# Postgres benchmark methodology (sc-inspector)

How **Spare Cores** measures managed and self-hosted Postgres for the Navigator. Implementation: `sc-inspector`, `sc-runner`, `sc-images` (`benchmark-pgbench-postgres`, `benchmark-postgres-server`), artifacts in `sc-inspector-data`.

## Goals and non-goals

**Goals**

- Comparable **pgbench TPM** across SKUs with a **cache-resident** working set.
- **RO** (`pgbench -S`, durable) and **TPC-B** (`tpcb-like`, async) on both topologies.
- Shared geometric concurrency rungs so machines can be compared at the same client counts, plus a short upward search for the peak.
- Persist enough metadata (all GUCs, profile rungs, provision context, server logs) to reproduce a run.

**Non-goals**

- BenchBase / HammerDB / YCSB in the live path (image trees may still exist for ad-hoc use).
- Equalizing storage fsync latency across clouds.
- Claiming colocated loopback TPS as the product number for multi-VM / DBaaS (those paths are networked by design).

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

## Live workloads: pgbench

| Task | Topology | Durability | Metric |
| ---- | -------- | ---------- | ------ |
| `pgbench_postgres_multi_ro_durable` | multi-VM | durable (`on`) | TPM |
| `pgbench_postgres_dbaas_ro_durable` | DBaaS | durable (`on`) | TPM |
| `pgbench_postgres_multi_tpcb_async` | multi-VM | async (`off`) | TPM |
| `pgbench_postgres_dbaas_tpcb_async` | DBaaS | async (`off`) | TPM |

**Durability**

- **durable:** production-default `synchronous_commit=on` (DBaaS: `ALTER ROLE … RESET` so vendor default applies).
- **async:** `synchronous_commit=off`. DBaaS async is skipped when the catalog / precheck reports `sync_commit_session_settable=false`.

## Schema sizing (discrete rungs ≤ ¼ RAM)

```
SCHEMA_SIZE_GIB = (1, 4, 16, 64)          # few fixed sizes for cross-SKU compare
cache_budget   = 0.25 × mem_gib          # ≈ shared_buffers (pgtune web/SSD)
# Disk plan: largest rung ≤ budget
# RO: fixed ~1 GiB (scale 65 ≈ 980 MB)
# TPC-B async: smallest rung whose pgbench scale ≥ concurrency_search_cap(V),
#             else largest rung ≤ budget (clients still capped at scale)
```

Multi-VM GUCs come from [pgtune.leopard.in.ua](https://pgtune.leopard.in.ua/) form defaults (`web` / SSD / PG18). Schema stays **inside Postgres caches**; 64 GiB covers the concurrency ladder max (3072 clients ≈ 45 GiB of pgbench data).

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

**Caveat:** network-attached fsync latency still differs by cloud/product; durable scores include storage commit cost by design.

## Concurrency ladder

Static geometric ladder (powers of two + midpoints):

`1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072`

Per host:

1. Always measure anchors `{1, rung(V/4), rung(V/2), rung(V)}`.
2. Then walk upward while TPM improves by ≥ **5%** vs the best so far.
3. Cap search at `rung(4V)` (and the ladder max).

TPC-B also enforces pgbench’s `-s ≥ -c` (branch/teller update contention otherwise). When the chosen size cannot cover the full host search cap, clients are capped at the scale factor and anchors are taken from `min(V, scale)`.

Inspector sets `SC_PROFILE=1` and `SC_PROFILE_VUS`. Headline `score` = max TPM across measured rungs.

## Timed run length

| Phase | Default | Env |
| ----- | ------- | --- |
| Warmup (once) | **120 s** | `SC_WARMUP_SECONDS` |
| Settle (later rungs) | **60 s** | `SC_SETTLE_SECONDS` |
| Measurement | **300 s** (5 min) | `SC_RUN_SECONDS` |

Full warmup runs only on the first timed rung; later rungs use the short settle (connection storm / cache already hot).

## Postgres configuration

### Multi-VM

GUCs from [pgtune.leopard.in.ua](https://pgtune.leopard.in.ua/) (`pgtune_leopard.generate_for_host`): form defaults `dbType=web`, `hdType=ssd`, `dbVersion=18`, `osType=linux`, `dbSize=mid_ram`; only host RAM and CPU count vary. Then set `synchronous_commit` from task durability. Applied via `postgres -c …`. Requested template: `postgres.requested_gucs`; share URL: `pgtune_share_url`; full live dump: `postgres.settings`.

Containers use elevated `nofile` / privileged / host network as needed for high `max_connections` and `io_uring` (see `DB_DOCKER_OPTS`).

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
| pgbench wrapper | `sc-images/images/benchmark-pgbench-postgres/benchmark.py` |

Historical BenchBase / HammerDB / YCSB runs may still exist under `data/` and `dbaas/`; they are **not** produced by the current live task matrix.

---

## Design decisions (why this shape)

Calibration was done on GCP with Postgres 18, pgtune leopard web/SSD defaults, and `shared_buffers` ≈ ¼ RAM. The live matrix below is what we kept; raw experiment trees are not required to operate the inspector.

### Why pgbench (not BenchBase / HammerDB)

- **RO (`-S`)** is a clean CPU / cache / connection ceiling: one prepared PK `SELECT` on `pgbench_accounts`. Fixed **scale 65 ≈ 980 MB** is enough — on large RAM hosts, RO TPM is flat from ~0.25–4 GiB (and even 1 GiB vs 64 GiB is within a few percent when both fit in shared buffers).
- **TPC-B (`tpcb-like`)** is the write path we care about for ranking under durability pressure (account + teller + branch updates + history insert).
- Heavier mixes (BenchBase wikipedia, HammerDB TPC-C) were useful for early exploration but add schema/build complexity without improving SKU ranking once we standardized on cache-resident pgbench. They are out of the live path for now.

### Why durable RO + async TPC-B

- **Durable RO** matches production defaults (`synchronous_commit=on`) for a read path that barely touches WAL.
- **Durable TPC-B saturates early** (on a 360 vCPU host, ~37 k TPS / ~2.3 M TPM by ~90 clients on 1 GiB; flat through 360 while P95 climbs). It is WAL/fsync-bound, not CPU-bound — so durable write scores barely move with core count once the fsync ceiling is hit.
- **Durable × large DB is a cliff** (64 GiB held only ~¼–⅓ of 1 GiB durable TPM; P95 stuck ~38 ms) from dirty-page / WAL amplification — opposite of RO, which stays flat across size when cache-resident.
- **Async TPC-B is 3–16× durable** and on large sizes can *beat* small-DB async at high concurrency. That makes async the useful write-side SKU differentiator; durable remains available in plumbing if we need an fsync-bound score later.
- vs RO on the same host: select-only peaked ~3 M TPS colocated; TPC-B durable ~38 k, async ~150 k — writes are ~80–200× slower. Both workloads stay in the matrix because they answer different questions.

### Why cache-resident discrete sizes

- Working set must stay under **~shared_buffers (¼ RAM)** so timed runs measure CPU/locking/commit behavior, not storage.
- A short GiB ladder **`(1, 4, 16, 64)`** keeps dump/CDN cardinality low and lets SKUs land on shared sizes for comparison.
- **RO** stays at the 1 GiB rung (scale 65); growing the RO schema does not change the ranking story.
- **TPC-B** picks the **smallest** ladder rung whose scale covers `concurrency_search_cap(V)` (see below), else the largest rung that still fits in cache. That implements pgbench’s documented rule without inventing a unique scale per SKU.

### Why `-s ≥ -c` for TPC-B

Postgres docs: for the default TPC-B-like script, initialization scale must be **at least as large as the largest `-c`**, otherwise you mostly measure branch/teller update contention (`pgbench_branches` has only `-s` rows). We size from the planned search cap and still cap clients at scale when RAM forces a smaller rung.

### Why the geometric ladder + 5% search

- Fleet vCPU counts are sparse; a **static** ladder (powers of two + midpoints) maximizes shared client counts across SKUs instead of densifying to every fleet shape.
- Always measure **anchors** `{1, V/4, V/2, V}` so small/medium/full host concurrency is present even if search stops early.
- Search upward while TPM improves ≥ **5%**, capped at **`rung(4V)`**, to find oversubscribe peaks (remote RO on a 360 vCPU server peaked near 540 clients, not at `nproc`) without unbounded wall time.
- Do **not** densify the ladder to match the fleet histogram — most hosts already land on an exact rung, and shared points matter more than per-SKU exactness.

### Why 2 min warmup + 5 min measure (warmup once)

- Interleaved duration studies (measure ∈ {5, 10, 15, 30} min, n=5) on both wikipedia-era and pgbench RO hosts showed **mean TPM within ~1–2%** of the 5 min mean at longer windows; longer runs did **not** systematically tighten CV (run-to-run noise dominates).
- Prefer spending wall clock on more SKUs / concurrency rungs / replicates over 10–30 min windows.
- After the first full warmup, later rungs only need a short **settle** (connection storm); caches and backends are already hot.

### Why multi-VM / DBaaS use a separate client

- Product topologies are networked (companion VM or VPC client → DB). Colocated loopback can hit multi-million RO TPS; same-VPC remote on the same server class peaked around **~43%** of colocated RO (~1.35 M vs ~3.15 M TPS) with **~2–3×** client-side latency.
- Little’s Law holds: \(TPS ≈ C / R\). The remote gap is mostly higher \(R\) (NIC + softirq), not missing Postgres CPU — servers stayed ~80% idle with `ksoftirqd` pegged.
- Companion client sizing therefore budgets for high client counts that multiplex well (many threads wait on RTT), not 1:1 vCPU mapping to `-c`.
- External/managed paths with higher RTT will score lower at the same `-c`; that is expected and should not be “corrected” away.

### Why shared disk IOPS/size across topologies

- Multi-VM and DBaaS use the same `storage_gib` and vendor performance contract so SKU compares are not confounded by accidentally different provisioned IOPS.
- Durable scores still include real fsync cost; we do not try to normalize clouds to identical commit latency.
