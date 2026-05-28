# Spare Cores Inspector Data

Data collected by [`sparecores-inspector`](https://github.com/SpareCores/sc-inspector)
under the `data` folder using the `vendor/server` directory structure, referring to the
vendor by its `vendor_id`, and using the `api_reference` for the server.


# Collected data

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
