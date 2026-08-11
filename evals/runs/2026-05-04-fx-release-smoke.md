# 2026-05-04 fx Release Smoke Run

## Summary

- Command: `./evals/scripts/run-release-evals.sh`
- Harbor job ID: `0edb8ddb-5da7-4529-816b-22d6030bb118`
- Harbor results: `evals/jobs-out/2026-05-04__17-47-44`
- Job config: `evals/jobs/fx-release.yaml`
- Dataset: `fx-release`
- Agent: `fx`
- Model: `anthropic/claude-sonnet-4.6`
- Runtime: 9m 56s
- Trials: 6
- Exceptions: 0
- Pass rate: 1.00
- Mean reward: 1.00

## Task Results

| Task | Reward |
| --- | ---: |
| `create-file` | 1 |
| `edit-file` | 1 |
| `run-command` | 1 |
| `grep-files` | 1 |
| `cli-with-tests` | 1 |
| `crud-api` | 1 |

## Interpretation

The freshly built `fx` binary completed all six deterministic Harbor release-smoke tasks. The run covered basic file creation, file editing, shell command execution, file search, a tested CLI project, and a tested CRUD API project.

Each captured `fx-exit-code.txt` was `0`, including the `crud-api` task.
