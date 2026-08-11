# 2026-05-04 fx Multi-step Smoke

Docs used:

- https://www.harborframework.com/docs/tasks
- https://www.harborframework.com/docs/tasks/multi-step
- https://www.harborframework.com/docs/datasets/adapters

Command:

```bash
./evals/scripts/run-release-evals.sh --multistep
```

Result:

- Job output: `evals/jobs-out/2026-05-04__19-11-55`
- Dataset: `fx-multistep`
- Agent: `fx`
- Model: `claude-sonnet-4.6`
- Trials: 1
- Pass rate: `1.00`
- Mean reward: `1.00`
- Harbor metrics: `mean_reward=1.00 pass_rate=1.00 n_trials=1 n_passed=1`
- Artifact collection failures: `0`

Notes:

- Both steps ran: `seed-report`, then `extend-report`.
- Per-step artifacts are under `steps/<step-name>/artifacts/`.
- Both step `fx-exit-code.txt` files contained `0`.
