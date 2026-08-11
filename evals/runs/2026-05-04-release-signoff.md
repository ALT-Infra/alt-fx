# 2026-05-04 fx release signoff

Viewer command:

```bash
uvx harbor view evals/jobs-out
```

## Summary

| Dataset | Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Result path |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `fx-release` | `fx` | `anthropic/claude-sonnet-4.6` | 6 | 6 | 1.00 | 1.00 | 0 | 0 | `evals/jobs-out/2026-05-04__21-29-30` |
| `terminal-bench/terminal-bench-2` | `fx` | `anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 | `evals/jobs-out/2026-05-04__21-38-19` |

## fx-release

- Result path: `evals/jobs-out/2026-05-04__21-29-30`
- Started: `2026-05-04T21:29:31.001721`
- Finished: `2026-05-04T21:38:17.888547`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fx` | `anthropic/claude-sonnet-4.6` | 6 | 6 | 1.00 | 1.00 | 0 | 0 |

Exceptions:
- none

Artifact failures:
- none

## terminal-bench/terminal-bench-2

- Result path: `evals/jobs-out/2026-05-04__21-38-19`
- Started: `2026-05-04T21:38:21.307293`
- Finished: `2026-05-04T21:43:43.289617`

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fx` | `anthropic/claude-sonnet-4.6` | 1 | 0 | 0.00 | 0.00 | 0 | 0 |

Exceptions:
- none

Artifact failures:
- none
