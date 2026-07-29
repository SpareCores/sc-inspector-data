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

**Rollout**

- Multi-VM pgbench tasks use `start_with_instance=True` (piggyback on other tasks; no SKU allowlist).
- DBaaS: Azure `Standard_E16ds_v5/postgres/18/standalone`; GCP `db-perf-optimized-N-8`, `N-16`, `N-128` (peer of GCE `n2-standard-128`), `db-memory-optimized-N-8` (each `/postgres/18/standalone`; Enterprise Plus **data cache off**)

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

Both topologies use `db_storage.db_storage_plan(vendor, mem_gib, vcpus)` so size and I/O scale with the VM. The goal is cross-vendor parity: disk should never bottleneck before CPU.

### vCPU-scaled I/O budget

```
target_write_mbps = max(50, vcpus × 1.5)     # MB/s per VM
target_write_iops = max(1000, vcpus × 25)    # IOPS per VM
```

n2-standard-128 showed TPC-B peaking at ~105–110K TPS whether the disk wrote ~310 or ~600 MB/s — lock/WAL contention, not bandwidth. Budget is halved vs the first pass so large SKUs stay near the old ~200 MB/s Azure/AWS target without the 800 GiB overshoot. The size floor (`max(64, ceil(schema × 2 / 0.85))`) still applies for data capacity.

### Vendor disk profiles (`disk_profiles.py`)

| Vendor | Disk type | Performance model | How I/O target is met |
| ------ | --------- | ----------------- | --------------------- |
| **GCP** | `pd-ssd` / Cloud SQL `PD_SSD` | Size-derived: 30 IOPS/GiB, 0.48 MB/s/GiB (cap 30K / 400 MB/s) | Provision a **larger disk** (e.g. 400 GiB for 128 vCPUs → 192 MB/s) |
| **Azure** | `PremiumV2_LRS` (DBaaS: ManagedDiskV2 / P30) | Independently provisioned | Set explicit **IOPS + throughput** |
| **AWS** | `gp3` | Independently provisioned (base 3K/125; max 16K/1000) | Set explicit **IOPS + throughput** |

Per-VM caps (GCP N2: 800 IOPS/vCPU, 6 MB/s/vCPU) are respected — the module never provisions more than the VM can consume.

| vCPUs | GCP pd-ssd GiB | GCP eff MB/s | Azure/AWS IOPS | Azure/AWS MB/s |
| -----:| --------------:| ------------:| --------------:| --------------:|
| 2 | 64 | 12 | 1000 | 50 |
| 16 | 105 | 50 | 1000 | 50 |
| 64 | 200 | 96 | 1600 | 96 |
| 128 | 400 | 192 | 3200 | 192 |

Ops overrides: `MULTI_VM_DB_DISK_TYPE`, `MULTI_VM_DB_DISK_IOPS`, `MULTI_VM_DB_DISK_THROUGHPUT`.

**Caveat:** network-attached fsync latency still differs by cloud/product; durable scores include storage commit cost by design.

## Concurrency ladder

Static geometric ladder (powers of two + midpoints):

`1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072`

Per host:

1. Always measure anchors `{1, rung(V/4), rung(V/2), rung(V)}`.
2. Then walk upward while TPM improves by ≥ **5%** vs the best so far.
3. Planned cap is `rung(4V)` (and ladder max) via `SC_PROFILE_MAX_CLIENTS`.
4. Adaptive extension can continue above the planned cap up to ladder max (`3072`) via `SC_PROFILE_HARD_MAX_CLIENTS` when the tail is still improving.

TPC-B also enforces pgbench’s `-s ≥ -c` (branch/teller update contention otherwise). When the chosen size cannot cover the full host search cap, clients are capped at the scale factor and anchors are taken from `min(V, scale)`.
For TPC-B, both planned and hard caps are set to that memory-derived client cap; adaptive extension beyond it is disabled.

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

GUCs from [pgtune.leopard.in.ua](https://pgtune.leopard.in.ua/) (`pgtune_leopard.generate_for_host`): form defaults `dbType=web`, `hdType=ssd`, `dbVersion=18`, `osType=linux`, `dbSize=mid_ram`; only host RAM and CPU count vary. Then set `synchronous_commit` from task durability, and raise `max_connections` to at least `CONCURRENCY_LADDER_MAX + 50` (3122) so RO adaptive extension to ladder max cannot hit `too many clients` (TPC-B may raise further to `scale + 50`). Applied via `postgres -c …`. Requested template: `postgres.requested_gucs`; share URL: `pgtune_share_url`; full live dump: `postgres.settings`. The pgbench driver also `SHOW max_connections` and clamps its client plan to `max_connections - 50` (important for DBaaS where the vendor caps connections).

Containers use elevated `nofile` / privileged / host network as needed for high `max_connections` and `io_uring` (see `DB_DOCKER_OPTS`).

### DBaaS

Vendor-managed GUC surface — no server-side pg_tune. Full `pg_settings` still snapshotted after the run. Role `synchronous_commit` set/reset for the durability task.

## Artifacts and S3

| Path | Contents |
| ---- | -------- |
| `<task>/stdout` | Single JSON: score, `sizes[].profile[]`, `postgres{}`, sizing, provision |
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
| Vendor disk profiles + vCPU scaling | `sc-inspector/inspector/disk_profiles.py` |
| Shared disk plan (uses profiles) | `sc-inspector/inspector/db_storage.py` |
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
- For **RO**, adaptive tail extension can continue from the planned `rung(4V)` cap up to ladder max (`3072`) while improvement holds.
- For **TPC-B**, hard cap is pinned to the memory-derived `-s` cap (still enforcing pgbench `-s ≥ -c`), so no extension beyond that point.
- Do **not** densify the ladder to match the fleet histogram — most hosts already land on an exact rung, and shared points matter more than per-SKU exactness.

### Why 2 min warmup + 5 min measure (warmup once)

- Interleaved duration studies (measure ∈ {5, 10, 15, 30} min, n=5) on both wikipedia-era and pgbench RO hosts showed **mean TPM within ~1–2%** of the 5 min mean at longer windows; longer runs did **not** systematically tighten CV (run-to-run noise dominates).
- Prefer spending wall clock on more SKUs / concurrency rungs / replicates over 10–30 min windows.
- After the first full warmup, later rungs only need a short **settle** (connection storm); caches and backends are already hot.

### Why multi-VM / DBaaS use a separate client

- Product topologies are networked (companion VM or VPC client → DB). Colocated loopback can hit multi-million RO TPS; same-VPC remote on the same server class peaked around **~43%** of colocated RO (~1.35 M vs ~3.15 M TPS) with **~2–3×** client-side latency.
- Little’s Law holds: \(TPS ≈ C / R\). The remote gap is mostly higher \(R\) (NIC + softirq), not missing Postgres CPU — servers stayed largely idle with backends in `ClientRead` while the companion burned **sys + softirq**.
- Companion sizing (`companion_client_vcpus`) therefore designs for **adaptive RO concurrency** (~3× the planned `rung(4V)` search cap, ladder-snapped) at about **20 clients per client vCPU**, and never below `V/2`. On n2-standard-128, a 64-vCPU companion saturated around 1–1.5 k clients while the DB still had headroom; the new rule yields ~77+ client vCPUs for that class so ranking measures the DB, not the client NIC.
- External/managed paths with higher RTT will score lower at the same `-c`; that is expected and should not be “corrected” away.

### Why vCPU-scaled disk I/O

- Schema-only sizing (151 GiB on n2-standard-128) under-documents sustained pd-ssd write; large SKUs need a vCPU-linked I/O floor so async TPC-B is not trivially storage-starved vs mid-size Azure/AWS targets (~200 MB/s).
- A first pass at 3 MB/s/vCPU (800 GiB / ~384 MB/s) did not raise TPC-B past ~110K TPS — peak waits were WALInsert / ProcArray / transactionid. Budget is **1.5 MB/s and 25 IOPS per vCPU** (~400 GiB / 192 MB/s at 128 vCPUs): still above the old floor, aligned with ~200 MB/s cross-vendor parity, without the 800 GiB overshoot.
- For size-derived types (GCP pd-ssd), this means provisioning a larger disk on bigger instances; for independently-provisioned types (Azure, AWS), it means requesting higher IOPS/throughput.
- The per-VM caps built into `disk_profiles.py` prevent over-provisioning beyond what the hypervisor can deliver.
- Multi-VM and DBaaS still use the same plan so SKU comparisons are not confounded by different I/O.
- Durable scores still include real fsync cost; we do not try to normalize clouds to identical commit latency.
