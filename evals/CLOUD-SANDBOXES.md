# Harbor Cloud Sandbox Notes

Local Docker remains the default for `fx` release evals. Cloud sandboxes are optional for larger published-dataset sweeps when local container startup and teardown dominate runtime.

Docs used for this slice:

- https://www.harborframework.com/docs/run-jobs/cloud-sandboxes
- https://www.harborframework.com/docs/datasets/publishing
- https://www.harborframework.com/docs/tasks/publishing
- https://www.harborframework.com/docs/sharing/sharing

## Prerequisites

Cloud runs need:

- Harbor auth for any private package references.
- A cloud sandbox provider account. The Harbor docs call out Daytona, Modal, E2B, and Runloop as options.
- Provider credentials configured outside this repository.
- A published dataset reference such as `vercel-labs-fx/fx-release@vX.Y.Z`.
- Agent credentials for the model-backed agent being tested.

Do not require Daytona or other cloud credentials for normal release evals.

## Command Template

Start with a small published-dataset run:

```bash
harbor run \
  -d "vercel-labs-fx/fx-release@vX.Y.Z" \
  -m "anthropic/claude-sonnet-4.6" \
  -a "<agent>" \
  -e daytona \
  -n 4
```

Increase `-n` only after the smoke passes and provider quotas are clear. The Harbor docs note that cloud sandboxes can parallelize well above local CPU count because command execution shifts to remote sandboxes, but release-team sweeps should still begin with low concurrency.

## Caveats

Daytona accounts may have internet restrictions by default. The Harbor docs mention the `HARBOR_NETWORK` coupon code for removing those restrictions. Treat that as an account setup step, not a repository prerequisite.

Daytona supports multi-container task deployments through `environment/docker-compose.yaml`. The Harbor docs state that Modal, E2B, and Runloop do not currently support multi-container environments, so use single-container tasks with those providers or keep multi-container tasks on Daytona or local Docker.

The current `fx-release` and `fx-multistep` tasks are single-container tasks. Local Docker is still the signoff path because it exercises the same local binary packaging path used by the release harness.

## What Not To Change

Do not edit the default local job YAMLs to require a cloud environment. Keep cloud sandbox commands as explicit operator commands so developers without provider credentials can still run:

```bash
./evals/scripts/run-release-evals.sh
./evals/scripts/run-release-evals.sh --multistep
./evals/scripts/run-terminal-bench.sh --smoke
```
