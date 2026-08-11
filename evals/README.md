# fx Release Evals

This folder contains manual Harbor release evals for `fx`. It adds a release benchmarking layer above the deterministic suites in `tests/e2e/`, the existing Bun evals in `tests/evals/`, and the startup benchmarks in `benchmarks/`. It does not replace those suites.

The intended release flow is:

```text
cut release -> run local fx release evals -> run Terminal-Bench smoke -> optionally run Terminal-Bench full or compare -> inspect happy/sad result
```

CI is intentionally out of scope for v1. These evals run real agents, require credentials, and can take minutes.

For the full operator guide, including single comparison runs, all configured eval types, result inspection, viewer usage, reporting, artifacts, publishing, RewardKit, and troubleshooting, read `evals/RUNBOOK.md`.

## Harbor Docs

Harbor docs and benchmark pages used by this harness:

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

## Prerequisites

- Zig 0.16 or newer
- Docker
- `uv`
- Harbor, either installed as `harbor` or runnable through `uvx harbor`
- `AI_GATEWAY_API_KEY` or `VERCEL_OIDC_TOKEN` for `fx`

Comparison runs also need:

- `AI_GATEWAY_API_KEY` for `fx`, Codex CLI, Claude Code, and OpenCode

Before a comparison run, check the environment and job config shape:

```bash
export AI_GATEWAY_API_KEY="<redacted>"
./evals/scripts/check-compare-ready.sh
```

The readiness script validates all eval job YAML files with Harbor `JobConfig`, checks the comparison agent import paths, and verifies `AI_GATEWAY_API_KEY` is present. It prints missing variable names, but it does not print secret values. To validate only YAML and Harbor config shape without credentials:

```bash
./evals/scripts/check-compare-ready.sh --config-only
```

Comparison runners do not modify local Claude Code, Codex, or OpenCode configuration. Codex CLI, Claude Code, and OpenCode receive container-scoped Vercel AI Gateway environment/config only for the Harbor process. The Codex comparison path does not read or upload the host Codex `auth.json`.

RewardKit is optional. The examples under `evals/rewardkit/` do not need RewardKit installed unless you want the local readiness script to run its tiny deterministic built-in criteria smoke. LLM and agent judges can cost money and must not run in normal release signoff unless explicitly enabled.

## Run

From the repository root:

```bash
./evals/scripts/check-release-ready.sh
./evals/scripts/run-release-signoff.sh
```

The signoff wrapper runs the required local `fx-release` evals, then the registered Terminal-Bench smoke, then writes a dated Markdown report under `evals/runs/` and updates `evals/runs/RUNS.md`.

Optional signoff flags:

```bash
./evals/scripts/run-release-signoff.sh --multistep
./evals/scripts/run-release-signoff.sh --compare
./evals/scripts/run-release-signoff.sh --full-terminal-bench
./evals/scripts/run-release-signoff.sh --compare --full-terminal-bench
./evals/scripts/run-release-signoff.sh --view
```

`--full-terminal-bench` is the explicit approval gate for the full Terminal-Bench dataset. `--compare --full-terminal-bench` is the explicit approval gate for the full multi-agent Terminal-Bench comparison. Both paths are slow and can cost money, so the wrapper prints warnings before running them.

Use the individual runners below for debugging a specific slice.

For only the local `fx-release` job:

```bash
./evals/scripts/run-release-evals.sh
```

For the comparison job:

```bash
./evals/scripts/check-release-ready.sh --compare
./evals/scripts/run-release-evals.sh --compare
```

For the separate multi-step smoke:

```bash
./evals/scripts/run-release-evals.sh --multistep
```

The runner builds a ReleaseSafe Linux `fx` binary, bakes it into the local `fx-evals:local` Docker image, runs Harbor, and prints a compact pass/fail summary.

After changing local task environments, solutions, or verifiers, run:

```bash
./evals/scripts/check-local-tasks.sh
```

This check expects `fx-evals:local` to exist. Run `./evals/scripts/build-image.sh` first after changing the binary or task environments.

For a non-publishing registry preflight:

```bash
./evals/scripts/check-publish-ready.sh
```

This validates local task names, dataset manifests, metric scripts, job config shape, and that generated Harbor output is not tracked. It does not call `harbor publish`.

For optional RewardKit example validation:

```bash
./evals/scripts/check-rewardkit-ready.sh
```

This parses RewardKit example TOML, checks the built-in criteria example shape, and runs a deterministic built-in criteria smoke only when `rewardkit` is importable locally. It skips LLM and agent judge execution unless `FX_REWARDKIT_RUN_JUDGES=1` is explicitly set.

For the registered Terminal-Bench smoke:

```bash
./evals/scripts/run-terminal-bench.sh --smoke
```

For the full Terminal-Bench run:

```bash
./evals/scripts/run-terminal-bench.sh --full
```

For the Terminal-Bench comparison smoke:

```bash
./evals/scripts/check-release-ready.sh --compare
./evals/scripts/run-terminal-bench.sh --smoke --compare
```

For the full comparison against `fx`, Codex CLI, Claude Code, and OpenCode, get explicit release-owner approval first:

```bash
./evals/scripts/run-terminal-bench.sh --full --compare
```

The Terminal-Bench runner builds the ReleaseSafe Linux `fx` binary and uploads it into each registered task container during `FxAgent.install()`. It does not require the `fx-evals:local` image for registered datasets.

## Dataset Modes

`fx-release` is a local dataset. The job YAML uses `path: evals/datasets/fx-release`, so Harbor runs the task directories from this checkout. This is the deterministic release gate for the local `fx` binary and the custom `fx-evals:local` image.

Terminal-Bench is a published dataset. The job YAML uses `name: terminal-bench/terminal-bench-2`, so Harbor resolves it from the registry and downloads tasks into `evals/.build/harbor-datasets`. `FxAgent` uploads the freshly built Linux `fx` binary into each registered task container during setup.

`fx-multistep` is a separate local dataset for Harbor step semantics. Its task uses `steps/<name>/instruction.md`, `steps/<name>/tests/test.sh`, and `steps/<name>/solution/solve.sh` so each verifier runs against state left by the previous step. It is not part of the default release gate.

Every job declares `evals/metrics/fx_metrics.py` as a Harbor `uv-script` metric. The metric emits `mean_reward`, `pass_rate`, `n_trials`, and `n_passed`, treating missing or null rewards as zero. The local dataset `metric.py` delegates to the shared script for direct local dataset runs.

RewardKit examples live in `evals/rewardkit/` and are documented in `evals/REWARDKIT.md`. They are not wired into `evals/jobs/fx-release.yaml`, Terminal-Bench jobs, or the default release runner.

## Coverage Boundaries

The release harness is configured for Harbor's local Linux Docker path, registered Terminal-Bench runs, metrics, artifacts, publishing preflight, cloud-sandbox command templates, optional multi-step coverage, optional RewardKit examples, and explicit multi-agent comparison.

The remaining Harbor docs describe capabilities that are intentionally not part of the default release gate:

- Windows tasks: not configured because `fx-release`, `fx-multistep`, and Terminal-Bench run in Linux containers. A Windows-targeted task would need `[environment].os = "windows"` plus `.bat` solution and verifier entrypoints.
- MCP sidecar tasks: not configured because none of the current release tasks need a sidecar service. Add `environment/docker-compose.yaml`, `environment.mcp_servers`, and health checks only when a task actually needs an MCP server or another service container.
- LLM-as-a-Judge and RewardKit judges: documented as opt-in examples only. The default release gate stays deterministic to avoid paid, subjective verifier drift.
- ATIF, SFT, and RL workflows: not configured as release gates. Harbor can consume ATIF trajectories for viewer, SFT, and RL workflows, and Codex or Claude Code may produce trajectories through Harbor's installed agents. The `fx` wrapper currently preserves a compact `fx` JSON result bundle rather than claiming first-class ATIF export.
- Terminus-2 and Harbor roadmap items: not in the default comparison matrix because the release comparison target set is `fx`, Codex CLI, Claude Code, and OpenCode. Add Terminus-2 only when a Harbor-native reference baseline is needed. Track roadmap-only items separately until they become released setup docs.
- Full Terminal-Bench: configured but explicitly gated by `--full-terminal-bench` because it is slow and can cost money.

## Publishing And Cloud Sandboxes

Publishing is private by default and is not part of normal release signoff. Use `evals/PUBLISHING.md` for the exact auth, sync, publish, tag, visibility, download, and run-by-reference commands. Do not publish or change package visibility unless the release owner explicitly asks for it.

Cloud sandboxes are optional for larger published-dataset sweeps. Local Docker remains the default for release evals. Use `evals/CLOUD-SANDBOXES.md` for Daytona-style command templates, concurrency guidance, internet restriction notes, and multi-container caveats.

## Artifacts

Raw Harbor output is written under `evals/jobs-out/<job-name>/`. Each trial has `result.json`, `trial.log`, and an `artifacts/manifest.json` that records collection status.

`FxAgent` writes a compact run bundle to `/logs/artifacts`, which Harbor collects by convention into the trial `artifacts/` directory:

- `fx-exit-code.txt`
- `fx-result.json`
- `fx-stderr.txt`
- `fx-wrapper.json`

The job configs also collect `/logs/agent` as `artifacts/agent`, `/logs/verifier` as `artifacts/verifier`, and `/app` as `artifacts/workspace`. The `fx`-only jobs additionally collect `/tmp/fx-home/.fx` as `artifacts/fx-home`; comparison jobs intentionally omit that `fx`-specific path so Codex CLI, Claude Code, and OpenCode runs do not produce expected artifact warnings.

The compact `/logs/artifacts` bundle is also collected as `artifacts/fx-run` by job config and may appear at the trial artifact root when Harbor copies installed-agent artifacts.

Workspace collection intentionally excludes bulky generated directories from `/app`: `node_modules`, `.git`, `.cache`, `__pycache__`, `.pytest_cache`, `dist`, `build`, `coverage`, `target`, `.venv`, and `venv`.

For multi-step tasks, Harbor collects artifacts once per step. Per-step manifests and files live under `evals/jobs-out/<job>/<trial>/steps/<step-name>/artifacts/`. The root `artifacts/manifest.json` remains the single-step location.

To inspect full results:

```bash
harbor view evals/jobs-out
```

Or use the runner shortcut:

```bash
./evals/scripts/run-terminal-bench.sh --view
```

Preserve human-readable run reports under `evals/runs/`. The signoff wrapper calls `evals/scripts/write-run-report.py`, which writes one dated Markdown file and updates `evals/runs/RUNS.md`. For manual reports:

```bash
./evals/scripts/write-run-report.py evals/jobs-out/<job-dir> [evals/jobs-out/<job-dir> ...]
```

Do not add top-level run log files in `evals/`.

## Release Signoff Flow

Default release signoff is one command:

```bash
./evals/scripts/run-release-signoff.sh
```

Decision criteria:

- `fx-release` must pass.
- Terminal-Bench smoke must complete without Harbor harness exceptions. The verifier score can be inspected separately because the smoke is a published benchmark sanity check, not the deterministic release gate.
- Comparison is recommended for major releases or before public benchmark claims.
- Full Terminal-Bench requires explicit release-owner approval through `--full-terminal-bench`.

Run these supporting checks before or during release signoff:

1. `./evals/scripts/check-release-ready.sh`
2. `./evals/scripts/run-release-signoff.sh`
3. `./evals/scripts/check-local-tasks.sh` after task or verifier edits
4. Optional multi-step coverage: `./evals/scripts/run-release-signoff.sh --multistep`
5. Recommended for major releases or before public benchmark claims: `./evals/scripts/run-release-signoff.sh --compare`
6. Full Terminal-Bench comparison requires explicit approval: `./evals/scripts/run-release-signoff.sh --compare --full-terminal-bench`
7. Optional publishing preflight only: `./evals/scripts/check-publish-ready.sh`

`fx-release` remains required for every release. Comparison evals are recommended for major releases or before public benchmark claims. Full Terminal-Bench comparison is slow and costly enough that it should only run after explicit approval.

RewardKit example validation is separate from release signoff:

```bash
./evals/scripts/check-rewardkit-ready.sh
```

Do not treat LLM or agent judge output as part of normal release signoff unless the release owner explicitly asks for that paid, slower workflow.

## Files

- `agents/fx_agent.py`: custom Harbor installed-agent wrapper that uploads the local Linux `fx` binary into each task container.
- `images/Dockerfile`: task base image with `/usr/local/bin/fx`.
- `datasets/fx-release/`: local Harbor dataset ported from the first release eval behaviors in `tests/evals/`.
- `datasets/fx-multistep/`: separate local Harbor dataset for sequential step coverage.
- `adapters/README.md`: manual adapter scaffold for porting future Bun evals into Harbor tasks.
- `PUBLISHING.md`: private-by-default Harbor publishing workflow.
- `CLOUD-SANDBOXES.md`: optional cloud sandbox command guide.
- `RUNBOOK.md`: full operator guide for running evals, comparisons, result inspection, reports, artifacts, and troubleshooting.
- `metrics/fx_metrics.py`: shared Harbor metric script used by every job.
- `jobs/fx-release.yaml`: local `fx` release job.
- `jobs/fx-multistep.yaml`: separate multi-step job for `fx`.
- `jobs/compare-key-agents.yaml`: local comparison job for `fx`, Codex CLI, Claude Code, and OpenCode.
- `jobs/fx-terminal-bench-smoke.yaml`: single-task registered Terminal-Bench smoke job for `fx`.
- `jobs/fx-terminal-bench.yaml`: full registered Terminal-Bench job for `fx`.
- `jobs/compare-terminal-bench-smoke.yaml`: single-task registered Terminal-Bench comparison job for `fx`, Codex CLI, Claude Code, and OpenCode.
- `jobs/compare-terminal-bench.yaml`: full registered Terminal-Bench comparison job for `fx`, Codex CLI, Claude Code, and OpenCode.
- `runs/`: dated, human-readable run reports and `RUNS.md` index.
- `REWARDKIT.md`: optional RewardKit policy and workflow for release evals.
- `rewardkit/`: example RewardKit criteria files, not connected to release jobs.
- `scripts/build-image.sh`: builds the Linux binary and Docker image.
- `scripts/check-local-tasks.sh`: runs checked-in local task solutions and verifiers in Docker.
- `scripts/check-publish-ready.sh`: non-publishing registry readiness wrapper.
- `scripts/check-publish-ready.py`: non-publishing registry readiness checks.
- `scripts/check-rewardkit-ready.sh`: optional RewardKit example readiness wrapper.
- `scripts/check-rewardkit-ready.py`: local RewardKit example shape checks.
- `scripts/check-compare-ready.sh`: comparison credential and Harbor job config readiness wrapper.
- `scripts/check-compare-ready.py`: safe comparison env, YAML, import-path, and `JobConfig` checks.
- `scripts/check-release-ready.sh`: consolidated release readiness wrapper for tools, Docker, credentials, job config shape, publishing, RewardKit, and optional comparison credentials.
- `scripts/run-release-evals.sh`: one-command local runner.
- `scripts/run-terminal-bench.sh`: one-command Terminal-Bench runner.
- `scripts/run-release-signoff.sh`: one-command release signoff wrapper for local release evals, Terminal-Bench, optional comparison, optional multi-step, reporting, and viewer launch.
- `scripts/summarize-results.py`: compact benchmark summary report.
- `scripts/write-run-report.py`: Markdown report generator for one or more Harbor job output directories.
