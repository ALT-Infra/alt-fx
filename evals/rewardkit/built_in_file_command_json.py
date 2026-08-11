"""Example RewardKit built-in criteria for deterministic fx task checks.

This file is not wired into release signoff. It shows the shape a future Harbor
task could place under its tests directory if that task deliberately adopts
RewardKit built-in criteria.
"""

import rewardkit as rk


rk.file_exists("summary.json", weight=1.0)
rk.file_contains("summary.json", '"status": "ok"', weight=1.0)

rk.command_succeeds("python3 -m json.tool summary.json", timeout=10, weight=1.0)
rk.command_output_contains(
    "python3 -c \"import json; print(json.load(open('summary.json'))['status'])\"",
    "ok",
    timeout=10,
    weight=1.0,
)

rk.json_key_equals("summary.json", "status", "ok", weight=1.0)
rk.json_path_equals("summary.json", "checks.build", "pass", weight=1.0)
