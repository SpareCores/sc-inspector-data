# Postgres benchmark methodology (sc-inspector)

How **Spare Cores** measures managed and self-hosted Postgres for the Navigator. Implementation: `sc-inspector`, `sc-runner`, `sc-images` (`benchmark-pgbench-postgres`, `benchmark-postgres-server`), artifacts in `sc-inspector-data`.

Calibration and design rationale live in `sc-db-benchmark-tmp/RESULTS.md` (pgbench RO/TPC-B studies, pgtune GUC defaults).

## Goals and non-goals

**Goals**

- Comparable **pgbench TPM** across SKUs with a **cache-resident** working set.
- **RO** (`pgbench -S`, durable) and **TPC-B** (`tpcb-like`, async) on both topologies.
- Geometric concurrency anchors `{1, V/4, V/2, V}` plus upward search while TPM improves ≥5%, with **5-minute** measurement windows.
- Persist enough metadata (all GUCs, profile rungs, provision context, server logs) to reproduce a run.

**Non-goals**

- BenchBase / HammerDB / YCSB in the live path (image trees may still exist for ad-hoc use).
- Equalizing storage fsync latency across clouds.

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
# RO: fixed ~1 GiB (scale 65)
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

Geometric anchors `{1, rung(V/4), rung(V/2), rung(V)}`, then search upward while TPM improves ≥5% (cap `rung(4V)`). TPC-B also enforces pgbench’s `-s ≥ -c`.

Inspector sets `SC_PROFILE=1` and `SC_PROFILE_VUS`. Headline `score` = max TPM across measured rungs.

## Timed run length

| Phase | Default | Env |
| ----- | ------- | --- |
| Warmup (once) | **120 s** | `SC_WARMUP_SECONDS` |
| Settle (later rungs) | **60 s** | `SC_SETTLE_SECONDS` |
| Measurement | **300 s** (5 min) | `SC_RUN_SECONDS` |

Duration studies in `sc-db-benchmark-tmp/RESULTS.md` support 2 min warmup + 5 min measure for SKU ranking.

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
| pgbench wrapper | `sc-images/images/benchmark-pgbench-postgres/benchmark.py` |
| Calibration notes | `sc-db-benchmark-tmp/RESULTS.md` |

Historical BenchBase / HammerDB / YCSB runs may still exist under `data/` and `dbaas/`; they are **not** produced by the current live task matrix.
