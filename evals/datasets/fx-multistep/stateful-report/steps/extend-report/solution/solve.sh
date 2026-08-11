#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
from pathlib import Path

path = Path("/app/tasks.json")
tasks = json.loads(path.read_text(encoding="utf-8"))
tasks.append({"id": "review", "status": "blocked"})
path.write_text(json.dumps(tasks, indent=2) + "\n", encoding="utf-8")
PY

cat > /app/report.py <<'PY'
#!/usr/bin/env python3
import json
from collections import Counter
from pathlib import Path

tasks = json.loads(Path("tasks.json").read_text(encoding="utf-8"))
counts = Counter(task["status"] for task in tasks)
for status in ("blocked", "closed", "open"):
    print(f"{status}: {counts[status]}")
PY

chmod 0755 /app/report.py
python3 /app/report.py > /app/report.txt
chown agent:agent /app/tasks.json /app/report.py /app/report.txt
