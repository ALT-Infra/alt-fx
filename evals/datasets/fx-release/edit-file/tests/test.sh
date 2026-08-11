#!/usr/bin/env bash
set -u

mkdir -p /logs/verifier

python3 - <<'PY'
import json
from pathlib import Path

path = Path("/app/config.json")
ok = False
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    ok = (
        data.get("port") == 8080
        and data.get("debug") is True
        and data.get("name") == "my-app"
        and data.get("logLevel") == "info"
    )
except (OSError, json.JSONDecodeError):
    ok = False

Path("/logs/verifier/reward.txt").write_text("1\n" if ok else "0\n", encoding="utf-8")
PY
