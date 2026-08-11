# fx Eval Run History

This file indexes preserved Harbor eval run notes. Raw Harbor output is written to `evals/jobs-out/`, which is intentionally ignored because it contains bulky local artifacts.

Use one dated Markdown file per meaningful run:

```text
evals/runs/YYYY-MM-DD-<short-description>.md
```

Do not create top-level run logs in `evals/`; keep dated reports in this folder.

Reference docs and benchmark pages:

- https://www.harborframework.com/docs
- https://www.harborframework.com/docs/getting-started
- https://www.harborframework.com/docs/core-concepts
- https://www.harborframework.com/docs/migration
- https://www.harborframework.com/docs/run-jobs
- https://www.harborframework.com/docs/run-jobs/run-evals
- https://www.harborframework.com/docs/run-jobs/results-and-artifacts
- https://www.harborframework.com/docs/run-jobs/cloud-sandboxes
- https://www.harborframework.com/docs/tasks
- https://www.harborframework.com/docs/tasks/multi-step
- https://www.harborframework.com/docs/tasks/task-difference
- https://www.harborframework.com/docs/tasks/task-tutorial
- https://www.harborframework.com/docs/tasks/windows-container-support
- https://www.harborframework.com/docs/tasks/publishing
- https://www.harborframework.com/docs/datasets
- https://www.harborframework.com/docs/datasets/metrics
- https://www.harborframework.com/docs/datasets/adapters
- https://www.harborframework.com/docs/datasets/adapters-human
- https://www.harborframework.com/docs/datasets/publishing
- https://www.harborframework.com/docs/sharing/sharing
- https://www.harborframework.com/docs/agents
- https://www.harborframework.com/docs/agents/trajectory-format
- https://www.harborframework.com/docs/agents/terminus-2
- https://www.harborframework.com/docs/tutorials/running-terminal-bench
- https://www.harborframework.com/docs/tutorials/mcp-server-task
- https://www.harborframework.com/docs/tutorials/llm-as-a-judge
- https://www.harborframework.com/docs/rewardkit
- https://www.harborframework.com/docs/rewardkit/judge-criteria
- https://www.harborframework.com/docs/rewardkit/built-in-criteria
- https://www.harborframework.com/docs/rewardkit/motivation
- https://www.harborframework.com/docs/training-workflows/sft
- https://www.harborframework.com/docs/training-workflows/rl
- https://www.harborframework.com/docs/contributing/roadmap
- https://hub.harborframework.com/datasets/terminal-bench/terminal-bench-2/latest

## Dataset And Artifact Notes

Local release runs use `path: evals/datasets/fx-release`. Published Terminal-Bench runs use `name: terminal-bench/terminal-bench-2` and download registry tasks into `evals/.build/harbor-datasets`.

The separate multi-step run uses `path: evals/datasets/fx-multistep`. It exercises Harbor's `steps/` layout and keeps per-step instruction, solution, and verifier files under each step directory.

Every job uses `evals/metrics/fx_metrics.py` for explicit Harbor metrics: `mean_reward`, `pass_rate`, `n_trials`, and `n_passed`. Each trial collects a compact `/logs/artifacts` bundle plus agent logs, verifier logs, and workspace evidence. `fx`-only jobs also collect `fx` home state. Comparison jobs omit that `fx`-specific path so non-`fx` agents do not produce expected artifact warnings. Multi-step run artifacts appear under `steps/<step-name>/artifacts/` for each step.

RewardKit examples live under `evals/rewardkit/` and are documented in `evals/REWARDKIT.md`. They are optional examples only and are not connected to default release signoff jobs. LLM and agent judges are slower, can cost money, and require explicit opt-in.

Workspace artifacts exclude bulky generated directories from `/app`: `node_modules`, `.git`, `.cache`, `__pycache__`, `.pytest_cache`, `dist`, `build`, `coverage`, `target`, `.venv`, and `venv`. Check each trial's `artifacts/manifest.json` for collection status.

Publishing is private by default and remains an explicit release-owner action. Use `evals/PUBLISHING.md` for auth, sync, publish, tag, visibility, download, and run-by-reference commands. Use `./evals/scripts/check-publish-ready.sh` for a non-publishing local preflight.

Cloud sandboxes are optional for larger published-dataset sweeps. Use `evals/CLOUD-SANDBOXES.md` for Daytona-style commands and caveats. Local Docker remains the default release signoff environment.

Windows tasks, MCP sidecar tasks, LLM-as-a-Judge verifiers, ATIF export, SFT export, RL rollout integration, Terminus-2 baselines, and roadmap-only items are not part of the default release signoff. They are documented in `evals/README.md` as optional Harbor capabilities to add only when a release or benchmark claim needs them.

## Release Signoff Runs

The default release signoff sequence is now one wrapper:

```bash
./evals/scripts/run-release-signoff.sh
```

The wrapper runs local `fx-release`, runs Terminal-Bench smoke, writes a dated report in this folder, and updates this index. Use the older individual commands only when debugging a specific slice.

Decision criteria:

- `fx-release` must pass.
- Terminal-Bench smoke must complete without Harbor harness exceptions.
- Comparison is recommended for major releases or before public benchmark claims.
- Full Terminal-Bench requires explicit release-owner approval through `--full-terminal-bench`.

Supporting commands:

1. Consolidated preflight: `./evals/scripts/check-release-ready.sh`
2. Default signoff: `./evals/scripts/run-release-signoff.sh`
3. After task or verifier edits, local task oracle checks: `./evals/scripts/check-local-tasks.sh`
4. Optional multi-step coverage: `./evals/scripts/run-release-signoff.sh --multistep`
5. Recommended comparison path: `./evals/scripts/run-release-signoff.sh --compare`
6. Full Terminal-Bench comparison with explicit approval: `./evals/scripts/run-release-signoff.sh --compare --full-terminal-bench`
7. Optional publishing preflight only: `./evals/scripts/check-publish-ready.sh`

`fx-release` remains required for every release. Comparison evals are recommended for major releases and before public benchmark claims. Full Terminal-Bench comparison is not part of the default release path because it is slow and can cost money across all agents.

Optional RewardKit example validation is separate from release signoff:

```bash
./evals/scripts/check-rewardkit-ready.sh
```

This validates example TOML and deterministic built-in criteria shape without running paid judge evals by default.

Manual report generation for existing Harbor output:

```bash
./evals/scripts/write-run-report.py evals/jobs-out/<job-dir> [evals/jobs-out/<job-dir> ...]
```

## Runs

| Date | Run | Agent | Model | Pass Rate | Mean Reward | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-05-05 | [fx comparison signoff fixed](2026-05-05-comparison-signoff-fixed.md) | `varies` | `varies` | `see report` | `see report` | fx-release: claude-code 1.00/codex 1.00/fx 1.00/opencode 0.67, terminal-bench/terminal-bench-2: claude-code 1.00/codex 1.00/fx 0.00/opencode 0.00 |
| 2026-05-05 | [fx comparison signoff](2026-05-05-comparison-signoff.md) | `varies` | `varies` | `see report` | `see report` | fx-release: claude-code 0.00/codex 1.00/fx 1.00/opencode 0.00, terminal-bench/terminal-bench-2: claude-code 1.00/codex 1.00/fx 0.00/opencode 0.00 |
| 2026-05-04 | [fx comparison signoff](2026-05-04-comparison-signoff.md) | `varies` | `varies` | `see report` | `see report` | fx-release: claude-code 0.00/codex 0.00/fx 1.00/opencode 0.00, terminal-bench/terminal-bench-2: claude-code 1.00/codex 0.00/fx 0.00/opencode 0.00 |
| 2026-05-04 | [fx release signoff](2026-05-04-release-signoff.md) | `varies` | `varies` | `see report` | `see report` | fx-release: fx 1.00, terminal-bench/terminal-bench-2: fx 0.00 |
| 2026-05-04 | [fx release task slice](2026-05-04-fx-release-task-slice.md) | `fx` | `claude-sonnet-4.6` | `1.00` | `1.00` | 6 trials, 8m 9s, fixed `cli-with-tests` path scored 1, 0 exceptions, 0 artifact collection failures. |
| 2026-05-04 | [fx multi-step smoke](2026-05-04-fx-multistep-smoke.md) | `fx` | `claude-sonnet-4.6` | `1.00` | `1.00` | 1 trial, 2 sequential steps, 1m 6s, explicit metrics, 0 artifact collection failures. |
| 2026-05-04 | [fx release smoke](2026-05-04-fx-release-smoke.md) | `fx` | `claude-sonnet-4.6` | `1.00` | `1.00` | 6 trials, 9m 56s, 0 exceptions, captured fx exit code 0 for each task. |
| 2026-05-04 | [Terminal-Bench smoke](2026-05-04-terminal-bench-smoke.md) | `fx` | `claude-sonnet-4.6` | `0.00` | `0.00` | 1 trial, 0 exceptions, captured fx exit code 0. |
