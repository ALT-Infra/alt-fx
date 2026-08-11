#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

python3 - <<'PY'
import json
import subprocess
from pathlib import Path

log_path = Path("/logs/verifier/extend-report.txt")
reward_path = Path("/logs/verifier/reward.txt")
ok = False
messages = []

try:
    tasks = json.loads(Path("/app/tasks.json").read_text(encoding="utf-8"))
    expected = [
        {"id": "draft", "status": "open"},
        {"id": "ship", "status": "closed"},
        {"id": "review", "status": "blocked"},
    ]
    if tasks != expected:
        messages.append(f"unexpected tasks.json: {tasks!r}")

    expected_output = "blocked: 1\nclosed: 1\nopen: 1\n"
    result = subprocess.run(
        ["python3", "/app/report.py"],
        cwd="/app",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.stdout != expected_output:
        messages.append(f"unexpected stdout: {result.stdout!r}")
    if result.returncode != 0:
        messages.append(f"report.py exited {result.returncode}: {result.stderr!r}")

    try:
        report_txt = Path("/app/report.txt").read_text(encoding="utf-8")
    except OSError as exc:
        report_txt = ""
        messages.append(f"could not read report.txt: {exc}")
    if report_txt != expected_output:
        messages.append(f"unexpected report.txt: {report_txt!r}")

    ok = not messages
except Exception as exc:
    messages.append(f"{type(exc).__name__}: {exc}")

log_path.write_text("\n".join(messages) + ("\n" if messages else "ok\n"), encoding="utf-8")
reward_path.write_text("1\n" if ok else "0\n", encoding="utf-8")
PY
