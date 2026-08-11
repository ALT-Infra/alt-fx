# Terminal-Bench Smoke

Command:

```bash
./evals/scripts/run-terminal-bench.sh --smoke
```

Result:

- Dataset: `terminal-bench/terminal-bench-2`
- Harbor output: `evals/jobs-out/2026-05-04__17-39-21`
- Agent: `fx`
- Version: `0.3.2`
- Model: `claude-sonnet-4.6`
- Trials: `1`
- Exceptions: `0`
- Mean reward: `0.000`
- Pass rate: `0.00`
- Captured fx exit code: `0`

The smoke path completed without the doom-loop permission abort. The verifier scored the task `0.0` because the generated `out.html` did not trigger the required alert after filtering.

Viewer command:

```bash
uvx harbor view evals/jobs-out
```
