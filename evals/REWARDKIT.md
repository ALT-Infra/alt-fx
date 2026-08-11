# RewardKit In fx Release Evals

RewardKit is optional for this eval slice. It can make some Harbor verifier criteria easier to share, but it does not replace the checked-in deterministic bash verifiers under `evals/datasets/*/*/tests/test.sh`.

Reference docs:

- https://www.harborframework.com/docs/rewardkit
- https://www.harborframework.com/docs/rewardkit/built-in-criteria
- https://www.harborframework.com/docs/rewardkit/judge-criteria
- https://www.harborframework.com/docs/rewardkit/motivation
- https://www.harborframework.com/docs/agents/trajectory-format
- https://www.harborframework.com/docs/tutorials/llm-as-a-judge

## Default Release Signoff

Normal fx release signoff must continue to use the existing deterministic release path:

1. `./evals/scripts/run-release-signoff.sh`
2. `./evals/scripts/check-local-tasks.sh` after task or verifier edits

Those checks use explicit task scripts and deterministic verifiers. They are the release signal because they are inspectable, cheap enough to repeat, and do not depend on a model judging its own output.

Do not add LLM or agent judges to normal release signoff unless the release owner explicitly asks for that specific run.

## Which Verifier To Use

| Verifier shape | Use it for | Release signoff default |
| --- | --- | --- |
| Deterministic bash verifier | Exact filesystem, command, JSON, CLI, and test outcomes. This is the right default when a task has objective pass/fail behavior. | Yes |
| RewardKit built-in criteria | Concise deterministic file, command, JSON, CSV, HTTP, image, or trajectory checks when RewardKit is already part of the task verifier. Prefer this for small future Harbor tasks, not as a silent rewrite of existing release verifiers. | No, unless the task has explicitly adopted it |
| RewardKit LLM judge | Qualitative review such as readability, risk quality, explanation quality, or release-note usefulness. Use only after objective checks pass. | No |
| RewardKit agent judge | Qualitative review that needs workspace exploration or command execution. This is slower and broader than an LLM judge. | No |
| Trajectory-oriented criteria | Future process review if `fx` or Harbor emits ATIF trajectory artifacts for a task. Use it to inspect approach, tool usage, or turn budget, not final correctness. | No |

## Cost And Gating

RewardKit built-in criteria can be deterministic. LLM judges and agent judges are different:

- They are optional.
- They are slower than bash verifiers.
- They can cost money.
- They can depend on network access and provider credentials.
- They must not run during normal release signoff unless explicitly enabled.

Use `FX_REWARDKIT_RUN_JUDGES=1` only in a deliberate paid eval workflow. The local readiness script validates judge TOML shape by default but does not execute judge examples by default.

## Examples

The example criteria files live under `evals/rewardkit/`:

- `built_in_file_command_json.py`: built-in file, command, and JSON criteria.
- `qualitative_review.toml`: LLM judge rubric for qualitative review.
- `trajectory_review.toml`: optional future trajectory-oriented judge shape for ATIF-style artifacts.

Harbor's ATIF docs list Codex CLI and Claude Code as agents with automatic trajectory support. The custom `fx` wrapper does not claim that yet; it keeps `fx-result.json`, `fx-stderr.txt`, `fx-exit-code.txt`, and wrapper metadata in `/logs/artifacts`. Add true ATIF export only when process-quality judging, SFT export, or RL rollout work needs it.

These files are examples. They are not referenced by `evals/jobs/fx-release.yaml`, `evals/jobs/fx-terminal-bench-smoke.yaml`, or the default release runner.

## Local Readiness Check

Run this from the repository root:

```bash
./evals/scripts/check-rewardkit-ready.sh
```

The check:

- Parses checked-in task, dataset, and RewardKit example TOML.
- Validates the judge TOML example shape.
- Validates that the built-in criteria example mentions file, command, and JSON checks.
- Runs a tiny deterministic built-in criteria smoke only when `rewardkit` is already importable by the local Python interpreter.
- Skips LLM and agent judge execution unless explicitly enabled.

If RewardKit is not installed locally, the deterministic smoke is skipped. That skip is expected for normal release signoff.
