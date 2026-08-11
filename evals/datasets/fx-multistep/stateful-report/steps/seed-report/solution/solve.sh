#!/usr/bin/env bash
set -euo pipefail

cat > /app/tasks.json <<'JSON'
[
  {
    "id": "draft",
    "status": "open"
  },
  {
    "id": "ship",
    "status": "closed"
  }
]
JSON

cat > /app/report.py <<'PY'
#!/usr/bin/env python3
import json
from collections import Counter
from pathlib import Path

tasks = json.loads(Path("tasks.json").read_text(encoding="utf-8"))
counts = Counter(task["status"] for task in tasks)
print(f"open: {counts['open']}")
print(f"closed: {counts['closed']}")
PY

chmod 0755 /app/report.py
chown agent:agent /app/tasks.json /app/report.py
