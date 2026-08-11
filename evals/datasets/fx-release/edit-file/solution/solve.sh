#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
from pathlib import Path

path = Path("/app/config.json")
data = json.loads(path.read_text(encoding="utf-8"))
data["port"] = 8080
data["debug"] = True
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
