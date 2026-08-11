Continue from the files created in the previous step.

Update `tasks.json` by preserving the existing `draft` and `ship` tasks, then add exactly one new object:

```json
{"id": "review", "status": "blocked"}
```

Update `report.py` so running `python3 report.py` prints exactly:

```text
blocked: 1
closed: 1
open: 1
```

Run the report and write the same output to `report.txt`.
