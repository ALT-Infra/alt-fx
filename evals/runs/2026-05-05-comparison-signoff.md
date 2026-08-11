# 2026-05-05 fx comparison signoff

Viewer command:

```bash
uvx harbor view evals/jobs-out
```

## Summary

| Dataset | Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Result path |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `fx-release` | `claude-code` | `anthropic/claude-opus-4.7` | 6 | 0 | 0.00 | 0.00 | 6 | 6 | `evals/jobs-out/2026-05-05__00-24-47` |
| `fx-release` | `codex` | `openai/gpt-5.5` | 6 | 6 | 1.00 | 1.00 | 0 | 6 | `evals/jobs-out/2026-05-05__00-24-47` |
| `fx-release` | `fx` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__00-24-47` |
| `fx-release` | `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 | `evals/jobs-out/2026-05-05__00-24-47` |
| `terminal-bench/terminal-bench-2` | `claude-code` | `anthropic/claude-opus-4.7` | 1 | 1 | 1.00 | 1.00 | 0 | 1 | `evals/jobs-out/2026-05-05__01-28-07` |
| `terminal-bench/terminal-bench-2` | `codex` | `openai/gpt-5.5` | 1 | 1 | 1.00 | 1.00 | 0 | 1 | `evals/jobs-out/2026-05-05__01-28-07` |
| `terminal-bench/terminal-bench-2` | `fx` | `anthropic/claude-opus-4.7` | 1 | 0 | 0.00 | 0.00 | 0 | 0 | `evals/jobs-out/2026-05-05__01-28-07` |
| `terminal-bench/terminal-bench-2` | `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 1 | 1 | `evals/jobs-out/2026-05-05__01-28-07` |

## fx-release

- Result path: `evals/jobs-out/2026-05-05__00-24-47`
- Started: `2026-05-05T00:24:47.628170`
- Finished: `2026-05-05T01:27:50.170974`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-opus-4.7` | 6 | 0 | 0.00 | 0.00 | 6 | 6 |
| `codex` | `openai/gpt-5.5` | 6 | 6 | 1.00 | 1.00 | 0 | 6 |
| `fx` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |
| `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 |

Exceptions:
- claude-code/cli-with-tests: Traceback (most recent call last):
- opencode/cli-with-tests: Traceback (most recent call last):
- opencode/create-file: Traceback (most recent call last):
- claude-code/create-file: Traceback (most recent call last):
- opencode/crud-api: Traceback (most recent call last):
- claude-code/crud-api: Traceback (most recent call last):
- opencode/edit-file: Traceback (most recent call last):
- claude-code/edit-file: Traceback (most recent call last):
- claude-code/grep-files: Traceback (most recent call last):
- opencode/grep-files: Traceback (most recent call last):
- opencode/run-command: Traceback (most recent call last):
- claude-code/run-command: Traceback (most recent call last):

Artifact failures:
- claude-code/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed

## terminal-bench/terminal-bench-2

- Result path: `evals/jobs-out/2026-05-05__01-28-07`
- Started: `2026-05-05T01:28:09.628623`
- Finished: `2026-05-05T01:52:51.155403`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-opus-4.7` | 1 | 1 | 1.00 | 1.00 | 0 | 1 |
| `codex` | `openai/gpt-5.5` | 1 | 1 | 1.00 | 1.00 | 0 | 1 |
| `fx` | `anthropic/claude-opus-4.7` | 1 | 0 | 0.00 | 0.00 | 0 | 0 |
| `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 1 | 1 |

Exceptions:
- opencode/break-filter-js-from-html: Traceback (most recent call last):

Artifact failures:
- codex/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed

