# 2026-05-05 fx comparison signoff fixed

Viewer command:

```bash
uvx harbor view evals/jobs-out
```

## Summary

| Dataset | Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Result path |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `fx-release` | `claude-code` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__02-16-55` |
| `fx-release` | `codex` | `openai/gpt-5.5` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__02-16-55` |
| `fx-release` | `fx` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__02-16-55` |
| `fx-release` | `opencode` | `openai/anthropic/claude-sonnet-4.6` | 6 | 4 | 0.67 | 0.67 | 2 | 0 | `evals/jobs-out/2026-05-05__02-16-55` |
| `terminal-bench/terminal-bench-2` | `claude-code` | `anthropic/claude-opus-4.7` | 1 | 1 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__03-52-21` |
| `terminal-bench/terminal-bench-2` | `codex` | `openai/gpt-5.5` | 1 | 1 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-05__03-52-21` |
| `terminal-bench/terminal-bench-2` | `fx` | `anthropic/claude-opus-4.7` | 1 | 0 | 0.00 | 0.00 | 0 | 0 | `evals/jobs-out/2026-05-05__03-52-21` |
| `terminal-bench/terminal-bench-2` | `opencode` | `openai/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 | `evals/jobs-out/2026-05-05__03-52-21` |

## fx-release

- Result path: `evals/jobs-out/2026-05-05__02-16-55`
- Started: `2026-05-05T02:16:55.309074`
- Finished: `2026-05-05T03:50:30.681902`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |
| `codex` | `openai/gpt-5.5` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |
| `fx` | `anthropic/claude-opus-4.7` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |
| `opencode` | `openai/anthropic/claude-sonnet-4.6` | 6 | 4 | 0.67 | 0.67 | 2 | 0 |

Exceptions:
- opencode/cli-with-tests: harbor.trial.trial.AgentTimeoutError: Agent execution timed out after 360.0 seconds
- opencode/crud-api: harbor.trial.trial.AgentTimeoutError: Agent execution timed out after 420.0 seconds

Artifact failures:
- none

Auth and host config:
- Codex auth upload worked. Trial logs show the wrapper used `CODEX_AUTH_JSON_PATH` and linked the uploaded auth file inside container-local `CODEX_HOME`; no secret contents are printed in the report.
- No host Codex, Claude, or OpenCode config writes were made by the comparison wrappers. Claude used container-local `CLAUDE_CONFIG_DIR=/tmp/claude-code-config`, OpenCode wrote config/auth under the task container home, and Codex used container-local `CODEX_HOME` plus `/tmp/codex-secrets`.

## terminal-bench/terminal-bench-2

- Result path: `evals/jobs-out/2026-05-05__03-52-21`
- Started: `2026-05-05T03:52:23.365643`
- Finished: `2026-05-05T04:24:04.769849`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `claude-code` | `anthropic/claude-opus-4.7` | 1 | 1 | 1.00 | 1.00 | 0 | 0 |
| `codex` | `openai/gpt-5.5` | 1 | 1 | 1.00 | 1.00 | 0 | 0 |
| `fx` | `anthropic/claude-opus-4.7` | 1 | 0 | 0.00 | 0.00 | 0 | 0 |
| `opencode` | `openai/anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 |

Exceptions:
- none

Artifact failures:
- none
