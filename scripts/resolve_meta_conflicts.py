#!/usr/bin/env python3
"""Resolve meta.json merge conflicts by keeping ours when it matches current inspector hash."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSPECTOR = os.path.join(os.path.dirname(REPO), "sc-inspector")


def expected_hashes() -> dict[str, str]:
    sys.path.insert(0, os.path.join(INSPECTOR, "inspector"))
    from lib import DbaasDbTask, task_hash, get_tasks  # noqa: WPS433

    out: dict[str, str] = {}
    for vendor in ("gcp", "azure", "upcloud", "vultr", "hcloud", "ovh", "alicloud", "aws"):
        try:
            for task in get_tasks(vendor):
                if isinstance(task, DbaasDbTask):
                    continue
                out[task.name] = task_hash(task)
        except Exception:
            pass
    return out


def parse_side(block: str) -> dict | None:
    block = block.strip()
    if not block:
        return None
    return json.loads(block)


def restore_task_streams(rel: str) -> None:
    task_dir = os.path.dirname(rel)
    for stream in ("stdout", "stderr"):
        stream_rel = f"{task_dir}/{stream}"
        if subprocess.run(
            ["git", "-C", REPO, "checkout", "HEAD", "--", stream_rel],
            capture_output=True,
        ).returncode == 0:
            subprocess.run(["git", "-C", REPO, "add", stream_rel], capture_output=True)


def resolve_file(path: str, expected: dict[str, str]) -> bool:
    text = open(path, encoding="utf-8").read()
    if "<<<<<<<" not in text:
        return False
    task_name = os.path.basename(os.path.dirname(path))
    exp = expected.get(task_name)
    m = re.search(
        r"<<<<<<<[^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>>[^\n]*",
        text,
        re.DOTALL,
    )
    if not m:
        return False
    ours = parse_side(m.group(1))
    theirs = parse_side(m.group(2))
    if not ours:
        chosen = theirs
    elif exp and ours.get("task_hash") == exp:
        chosen = ours
    elif exp and theirs and theirs.get("task_hash") == exp:
        chosen = theirs
    else:
        chosen = ours
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(chosen, fh, separators=(",", ":"))
        fh.write("\n")
    restore_task_streams(os.path.relpath(os.path.dirname(path), REPO))
    return True


def main() -> int:
    expected = expected_hashes()
    status = subprocess.check_output(["git", "-C", REPO, "diff", "--name-only", "--diff-filter=U"], text=True)
    resolved = 0
    for rel in status.splitlines():
        if not rel.endswith("/meta.json"):
            continue
        path = os.path.join(REPO, rel)
        if resolve_file(path, expected):
            subprocess.check_call(["git", "-C", REPO, "add", rel])
            resolved += 1
            print(f"resolved {rel}")
    print(f"resolved {resolved} conflict(s)")
    return 0 if resolved or not status.strip() else 1


if __name__ == "__main__":
    raise SystemExit(main())
