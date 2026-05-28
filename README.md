# Spare Cores Inspector Data

Data collected by [`sparecores-inspector`](https://github.com/SpareCores/sc-inspector)
under the `data` folder using the `vendor/server` directory structure, referring to the
vendor by its `vendor_id`, and using the `api_reference` for the server.


# Collected data

## Timing

Each inspected instance may have a `timing/` directory (alongside task directories such as
`dmidecode/`). Files are plain text with a single UTC timestamp per line, in ISO-8601 form
(`YYYY-MM-DDTHH:MM:SSZ`). They are written to separate files (not `meta.json`) so the GitHub
Actions start workflow and the remote `inspect` run can commit independently.

| File | Stage | Written by |
|------|--------|------------|
| `api_start` | Start of successful Pulumi `runner.create` (per attempt, lock retries excluded) | Start workflow (`inspector start`) |
| `api_end` | Successful `runner.create` return | Start workflow |
| `user_data_start` | First line of `user_data.sh` on the host | Host user-data script |
| `user_data_end` | Immediately before `docker run inspect` on the host | Host user-data script |
| `inspector_start` | `inspector.py inspect` begins | Inspect container |
| `inspector_end` | `inspector.py inspect` finishes (all tasks done) | Inspect container |
| `machine_start` | Estimated OS boot time (`now − /proc/uptime`, second resolution) | Inspect container (`timing` task) |

The `timing` task is gated with `RUN_NEW_TASKS_ON_SERVERS` so enabling it does not restart all
machines. When it runs, it **always overwrites** `user_data_start`, `user_data_end`, and `machine_start`
(re-importing `user_data_*` from the host mount at `/host-timing`). `inspector_start` /
`inspector_end` are rewritten on each `inspect` run; `api_start` / `api_end` on each successful
`start`.

## PassMark

### Benchmark numbers

See [this forum entry](https://forums.passmark.com/performancetest/4599-formula-cpu-mark-memory-mark-and-disk-mark/page2#post54964).

### Viewing PassMark output

PassMark's [PerformanceTest](https://www.passmark.com/products/pt_linux/download.php) needs a terminal and prints its output with [ANSI escape codes](https://github.com/SpareCores/sc-inspector-data/blob/e49a5d4efe496e77ac8721e6b7910b138a2dff41/data/aws/r5.large/passmark/stderr#L1).

To view this output, you can use for example [ttyplay](https://manpages.ubuntu.com/manpages/noble/man1/ttyplay.1.html) if the file won't render correctly in your terminal
using a simple `cat`.
