Create two files in the current directory.

First, create `tasks.json` as a JSON array with exactly these two objects:

- `{"id": "draft", "status": "open"}`
- `{"id": "ship", "status": "closed"}`

Second, create `report.py`. When run with `python3 report.py`, it must read `tasks.json` and print exactly:

```text
open: 1
closed: 1
```
