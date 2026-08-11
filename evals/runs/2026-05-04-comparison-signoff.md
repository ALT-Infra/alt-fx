# 2026-05-04 fx comparison signoff

Viewer command:

```bash
uvx harbor view evals/jobs-out
```

## Summary

| Dataset | Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Result path |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `fx-release` | `claude-code` | `anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 | `evals/jobs-out/2026-05-04__21-51-17` |
| `fx-release` | `codex` | `openai/gpt-5.1-codex` | 6 | 0 | 0.00 | 0.00 | 6 | 6 | `evals/jobs-out/2026-05-04__21-51-17` |
| `fx-release` | `fx` | `anthropic/claude-sonnet-4.6` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-04__21-51-17` |
| `fx-release` | `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 | `evals/jobs-out/2026-05-04__21-51-17` |
| `terminal-bench/terminal-bench-2` | `claude-code` | `anthropic/claude-sonnet-4.6` | 1 | 1 | 1.00 | 1.00 | 0 | 1 | `evals/jobs-out/2026-05-04__22-43-22` |
| `terminal-bench/terminal-bench-2` | `codex` | `openai/gpt-5.1-codex` | 1 | 0 | 0.00 | 0.00 | 1 | 1 | `evals/jobs-out/2026-05-04__22-43-22` |
| `terminal-bench/terminal-bench-2` | `fx` | `anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 | `evals/jobs-out/2026-05-04__22-43-22` |
| `terminal-bench/terminal-bench-2` | `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 1 | 1 | `evals/jobs-out/2026-05-04__22-43-22` |

## fx-release

- Result path: `evals/jobs-out/2026-05-04__21-51-17`
- Started: `2026-05-04T21:51:17.938360`
- Finished: `2026-05-04T22:43:08.942353`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 |
| `codex` | `openai/gpt-5.1-codex` | 6 | 0 | 0.00 | 0.00 | 6 | 6 |
| `fx` | `anthropic/claude-sonnet-4.6` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |
| `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 6 | 0 | 0.00 | 0.00 | 6 | 6 |

Exceptions:
- claude-code/cli-with-tests: Traceback (most recent call last):
- codex/cli-with-tests: Traceback (most recent call last):
- opencode/cli-with-tests: Traceback (most recent call last):
- codex/create-file: Traceback (most recent call last):
- claude-code/create-file: Traceback (most recent call last):
- opencode/create-file: Traceback (most recent call last):
- codex/crud-api: Traceback (most recent call last):
- opencode/crud-api: Traceback (most recent call last):
- claude-code/crud-api: Traceback (most recent call last):
- codex/edit-file: Traceback (most recent call last):
- claude-code/edit-file: Traceback (most recent call last):
- opencode/edit-file: Traceback (most recent call last):
- codex/grep-files: Traceback (most recent call last):
- opencode/grep-files: Traceback (most recent call last):
- claude-code/grep-files: Traceback (most recent call last):
- claude-code/run-command: Traceback (most recent call last):
- opencode/run-command: Traceback (most recent call last):
- codex/run-command: Traceback (most recent call last):

Artifact failures:
- claude-code/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/cli-with-tests: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/create-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/crud-api: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/edit-file: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/grep-files: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- codex/run-command: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed

## terminal-bench/terminal-bench-2

- Result path: `evals/jobs-out/2026-05-04__22-43-22`
- Started: `2026-05-04T22:43:24.470433`
- Finished: `2026-05-04T23:02:19.202187`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-sonnet-4.6` | 1 | 1 | 1.00 | 1.00 | 0 | 1 |
| `codex` | `openai/gpt-5.1-codex` | 1 | 0 | 0.00 | 0.00 | 1 | 1 |
| `fx` | `anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 |
| `opencode` | `vercel/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 1 | 1 |

Exceptions:
- codex/break-filter-js-from-html: Traceback (most recent call last):
- opencode/break-filter-js-from-html: Traceback (most recent call last):

Artifact failures:
- codex/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- claude-code/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed
- opencode/break-filter-js-from-html: artifacts/manifest.json: /tmp/fx-home/.fx -> artifacts/fx-home: failed

