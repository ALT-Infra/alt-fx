# fx Harbor Eval Runbook

This is the operator guide for the Harbor eval harness under `evals/`. It covers how to run every configured eval path, how to run one comparison, how to find results, how to inspect artifacts, and how to decide whether a release passes.

Run every command from the repository root:

```bash
cd /Users/faxes/Developer/Fx/fx
```

Do not run bare `fx` for local verification. The eval scripts build and use the local binary from this checkout.

## What Is Configured

| Eval type | Job config | Runner | Agents | Default release gate |
| --- | --- | --- | --- | --- |
| Local release evals | `evals/jobs/fx-release.yaml` | `./evals/scripts/run-release-evals.sh` | `fx` | Yes |
| Local release comparison | `evals/jobs/compare-key-agents.yaml` | `./evals/scripts/run-release-evals.sh --compare` | `fx`, Codex CLI, Claude Code, OpenCode | Recommended before benchmark claims |
| Local multi-step smoke | `evals/jobs/fx-multistep.yaml` | `./evals/scripts/run-release-evals.sh --multistep` | `fx` | Optional |
| Terminal-Bench smoke | `evals/jobs/fx-terminal-bench-smoke.yaml` | `./evals/scripts/run-terminal-bench.sh --smoke` | `fx` | Yes, as harness sanity |
| Terminal-Bench full | `evals/jobs/fx-terminal-bench.yaml` | `./evals/scripts/run-terminal-bench.sh --full` | `fx` | Explicit approval only |
| Terminal-Bench comparison smoke | `evals/jobs/compare-terminal-bench-smoke.yaml` | `./evals/scripts/run-terminal-bench.sh --smoke --compare` | `fx`, Codex CLI, Claude Code, OpenCode | Recommended before benchmark claims |
| Terminal-Bench full comparison | `evals/jobs/compare-terminal-bench.yaml` | `./evals/scripts/run-terminal-bench.sh --full --compare` | `fx`, Codex CLI, Claude Code, OpenCode | Explicit approval only |

The one-command wrapper combines the release paths:

```bash
./evals/scripts/run-release-signoff.sh
```

By default it runs local `fx-release`, runs Terminal-Bench smoke, writes a dated report under `evals/runs/`, and updates `evals/runs/RUNS.md`.

## Prerequisites

Install or start:

- Zig 0.16 or newer
- Docker Desktop or Colima with a running Docker daemon
- `uv`
- Harbor, either as `harbor`, `uvx harbor`, or `uv tool run harbor`

Set credentials:

```bash
export AI_GATEWAY_API_KEY="<redacted>"
```

`fx`-only runs may also work with `VERCEL_OIDC_TOKEN`, but comparison runs require `AI_GATEWAY_API_KEY` because Codex CLI, Claude Code, and OpenCode are routed through Vercel AI Gateway inside task containers.

Comparison runs do not modify host Codex, Claude Code, or OpenCode config. The comparison wrappers create container-scoped config only for the Harbor task process.

## Preflight Checks

Run the normal release preflight:

```bash
./evals/scripts/check-release-ready.sh
```

Run the comparison preflight:

```bash
./evals/scripts/check-release-ready.sh --compare
```

Check only Harbor job config shape without credentials:

```bash
./evals/scripts/check-compare-ready.sh --config-only
```

After editing local task Dockerfiles, task TOML, oracle solutions, or verifier scripts, run:

```bash
./evals/scripts/build-image.sh
./evals/scripts/check-local-tasks.sh
```

## Release Signoff

Default release signoff:

```bash
./evals/scripts/check-release-ready.sh
./evals/scripts/run-release-signoff.sh
```

Default pass criteria:

- `fx-release` must pass.
- Terminal-Bench smoke must complete without Harbor harness exceptions.
- Artifact collection failures should be zero.
- The generated report should be added under `evals/runs/` if it is a meaningful release or comparison run.

Recommended major-release signoff with comparison:

```bash
./evals/scripts/check-release-ready.sh --compare
./evals/scripts/run-release-signoff.sh --compare
```

Optional multi-step coverage:

```bash
./evals/scripts/run-release-signoff.sh --multistep
```

Full Terminal-Bench release run, only after explicit approval:

```bash
./evals/scripts/run-release-signoff.sh --full-terminal-bench
```

Full Terminal-Bench comparison, only after explicit approval:

```bash
./evals/scripts/run-release-signoff.sh --compare --full-terminal-bench
```

Open the Harbor viewer after a signoff run:

```bash
./evals/scripts/run-release-signoff.sh --view
```

## Single Comparison

Use this when you want exactly one side-by-side comparison job on the local release dataset:

```bash
./evals/scripts/check-release-ready.sh --compare
./evals/scripts/run-release-evals.sh --compare
```

That runs `evals/jobs/compare-key-agents.yaml` against `evals/datasets/fx-release` with:

- `fx`
- Codex CLI
- Claude Code
- OpenCode

Use this when you want exactly one side-by-side Terminal-Bench smoke comparison:

```bash
./evals/scripts/check-release-ready.sh --compare
./evals/scripts/run-terminal-bench.sh --smoke --compare
```

Do not use the full Terminal-Bench comparison as a casual smoke:

```bash
./evals/scripts/run-terminal-bench.sh --full --compare
```

That path is intentionally slow and can cost money across all agents.

## Individual Eval Commands

Local `fx` release evals only:

```bash
./evals/scripts/run-release-evals.sh
```

Local comparison only:

```bash
./evals/scripts/run-release-evals.sh --compare
```

Local multi-step smoke only:

```bash
./evals/scripts/run-release-evals.sh --multistep
```

Terminal-Bench smoke for `fx` only:

```bash
./evals/scripts/run-terminal-bench.sh --smoke
```

Terminal-Bench full for `fx` only:

```bash
./evals/scripts/run-terminal-bench.sh --full
```

Terminal-Bench smoke comparison:

```bash
./evals/scripts/run-terminal-bench.sh --smoke --compare
```

Terminal-Bench full comparison:

```bash
./evals/scripts/run-terminal-bench.sh --full --compare
```

Open existing Harbor output without running a job:

```bash
./evals/scripts/run-terminal-bench.sh --view
```

## Results

Raw Harbor output is written to:

```text
evals/jobs-out/<timestamp>/
```

`evals/jobs-out/` is ignored by git because it can contain bulky local artifacts.

Each job directory normally contains:

- `config.json`: resolved Harbor job config.
- `job.log`: top-level Harbor run log.
- `result.json`: machine-readable job result and metrics.
- `lock.json`: Harbor lock metadata.
- one directory per trial.

Each trial normally contains:

- `result.json`: trial reward, exception, agent, model, and timing fields.
- `trial.log`: trial log.
- `artifacts/manifest.json`: artifact collection status.
- `artifacts/agent/`: agent logs and trajectories when available.
- `artifacts/verifier/`: verifier logs and `reward.txt`.
- `artifacts/workspace/`: collected `/app` workspace evidence.
- `artifacts/fx-run/`: compact `fx` wrapper bundle when produced.
- `artifacts/fx-home/`: only in `fx`-only jobs.

Multi-step jobs place step artifacts under:

```text
evals/jobs-out/<timestamp>/<trial>/steps/<step-name>/artifacts/
```

## Summaries

Print a compact summary for the latest job:

```bash
./evals/scripts/summarize-results.py evals/jobs-out
```

Print a compact summary for a specific job:

```bash
./evals/scripts/summarize-results.py evals/jobs-out/<timestamp>
```

The summary reports:

- `n_trials`
- `n_passed`
- `pass_rate`
- `mean_reward`
- failed tasks
- exceptions
- artifact collection failures
- per-agent comparison tables when the job has multiple agents

For comparison jobs, inspect both the summary and the generated report before making claims. A pass rate can hide timeouts or setup exceptions unless you check the exception and artifact sections.

## Viewer

Open the Harbor viewer:

```bash
harbor view evals/jobs-out
```

If Harbor is only available through `uvx`:

```bash
uvx harbor view evals/jobs-out
```

The runner also prints the correct viewer command after a run. Use:

```bash
./evals/scripts/run-terminal-bench.sh --view
```

The viewer is useful for drilling into trial logs, artifacts, rewards, exceptions, and trajectories.

## Reports

The signoff wrapper writes a dated Markdown report automatically:

```text
evals/runs/YYYY-MM-DD-release-signoff.md
```

It also updates:

```text
evals/runs/RUNS.md
```

Generate or regenerate a report manually:

```bash
./evals/scripts/write-run-report.py evals/jobs-out/<timestamp>
```

Generate one report from multiple job directories:

```bash
./evals/scripts/write-run-report.py \
  evals/jobs-out/<release-job> \
  evals/jobs-out/<terminal-bench-job>
```

For comparison signoff, include both the local comparison job and the Terminal-Bench comparison smoke job when generating a report.

## Artifacts To Check

Start with:

```text
evals/jobs-out/<timestamp>/result.json
evals/jobs-out/<timestamp>/job.log
```

Then inspect failed trials:

```text
evals/jobs-out/<timestamp>/<trial>/result.json
evals/jobs-out/<timestamp>/<trial>/trial.log
evals/jobs-out/<timestamp>/<trial>/artifacts/manifest.json
evals/jobs-out/<timestamp>/<trial>/artifacts/verifier/
evals/jobs-out/<timestamp>/<trial>/artifacts/agent/
evals/jobs-out/<timestamp>/<trial>/artifacts/workspace/
```

For `fx` trials, also check:

```text
artifacts/fx-run/fx-exit-code.txt
artifacts/fx-run/fx-result.json
artifacts/fx-run/fx-stderr.txt
artifacts/fx-run/fx-wrapper.json
```

Artifact collection failures should be treated as harness problems unless the path is explicitly optional and documented.

## Publishing And Cloud Sandboxes

Publishing is not part of default release signoff. Use:

```bash
./evals/scripts/check-publish-ready.sh
```

Then follow:

```text
evals/PUBLISHING.md
```

Cloud sandboxes are optional for larger published-dataset sweeps. Follow:

```text
evals/CLOUD-SANDBOXES.md
```

Local Docker remains the default environment for release signoff.

## RewardKit

RewardKit examples are optional and are not part of default release signoff.

Validate the examples:

```bash
./evals/scripts/check-rewardkit-ready.sh
```

The script parses example TOML and only runs deterministic RewardKit smoke checks when `rewardkit` is already importable locally. It does not run paid LLM or agent judges unless explicitly enabled:

```bash
FX_REWARDKIT_RUN_JUDGES=1 ./evals/scripts/check-rewardkit-ready.sh
```

Read:

```text
evals/REWARDKIT.md
```

## Troubleshooting

Docker daemon unavailable:

```bash
docker info
```

Start Docker Desktop or Colima, then rerun the preflight. On Colima, the scripts auto-detect `$HOME/.colima/default/docker.sock` when it exists.

Harbor command missing:

```bash
uvx harbor --help
```

The scripts use `harbor`, then `uvx harbor`, then `uv tool run harbor`.

Comparison preflight fails:

```bash
export AI_GATEWAY_API_KEY="<redacted>"
./evals/scripts/check-release-ready.sh --compare
```

The current comparison path does not require `CODEX_AUTH_JSON_PATH` or `CODEX_ALLOW_AUTH_UPLOAD`.

Local task verifier fails without a reward:

- Fix the verifier so every bad-solution path writes `/logs/verifier/reward.txt`.
- Rerun `./evals/scripts/check-local-tasks.sh`.

Host binary becomes the wrong architecture:

- This should not happen. `evals/scripts/build-image.sh` writes the Linux eval binary under `evals/.build/linux/bin/fx` and copies it to `evals/images/fx`.
- Rebuild the native binary with `zig build`.
- Confirm with `./zig-out/bin/fx help`.

Artifact warnings in comparison jobs:

- Comparison jobs intentionally do not collect `/tmp/fx-home/.fx`.
- If warnings appear, inspect `artifacts/manifest.json` and the job YAML artifact list.

Full Terminal-Bench takes too long or costs too much:

- Use smoke jobs by default.
- Require explicit release-owner approval before `--full` or `--full-terminal-bench`.

## Git Hygiene

Do not commit local Harbor output:

```text
evals/.build/
evals/jobs-out/
evals/images/fx
evals/**/__pycache__/
evals/**/*.pyc
```

Check before committing:

```bash
git status --short --ignored=matching .gitignore evals
```

Only tracked docs, scripts, job configs, task definitions, metrics, adapters, and preserved run reports should be committed.
