# 2026-05-04 fx Release Task Slice

Docs used:

- https://www.harborframework.com/docs/tasks
- https://www.harborframework.com/docs/tasks/multi-step
- https://www.harborframework.com/docs/datasets/adapters

Command:

```bash
./evals/scripts/run-release-evals.sh
```

Result:

- Job output: `evals/jobs-out/2026-05-04__19-15-20`
- Dataset: `fx-release`
- Agent: `fx`
- Model: `claude-sonnet-4.6`
- Trials: 6
- Pass rate: `1.00`
- Mean reward: `1.00`
- Harbor metrics: `mean_reward=1.00 pass_rate=1.00 n_trials=6 n_passed=6`
- Artifact collection failures: `0`

Notes:

- `cli-with-tests` passed and wrote `artifacts/verifier/project-dir.txt` with `/app`.
- `cli-with-tests` compact artifact bundle has `fx-exit-code.txt` in both the Harbor-installed artifact root and `artifacts/fx-run/`; both contained `0`.
