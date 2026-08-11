# Harbor Publishing Notes

These notes are for release-team publishing dry runs and future registry handoff. Normal release evals stay local and do not publish anything.

Docs used for this slice:

- https://www.harborframework.com/docs/datasets/publishing
- https://www.harborframework.com/docs/tasks/publishing
- https://www.harborframework.com/docs/sharing/sharing
- https://www.harborframework.com/docs/run-jobs/cloud-sandboxes

## Defaults

Harbor publishes tasks and datasets privately unless `--public` is passed. Keep `fx-release` and `fx-multistep` private by default. Do not change visibility or publish from automation unless the release owner explicitly asks for it.

Current local package names:

- `vercel-labs-fx/fx-release`
- `vercel-labs-fx/fx-multistep`

## Preflight

From the repository root:

```bash
./evals/scripts/check-publish-ready.sh
harbor auth status
```

If not signed in:

```bash
harbor auth login
harbor auth status
```

The readiness script only checks local structure. It validates task names, dataset manifests, metric scripts, job config shape, and that generated Harbor output is not tracked. It never calls `harbor publish`.

## Sync

Before publishing, inspect the dataset manifest and refresh Harbor digests intentionally:

```bash
cd evals/datasets/fx-release
harbor add "." --scan
harbor add metric.py
harbor sync
```

For the multi-step dataset:

```bash
cd evals/datasets/fx-multistep
harbor add "." --scan
harbor sync
```

`harbor publish` refreshes local task and metric digests during upload, but an explicit `harbor sync` gives reviewers a separate manifest diff to inspect first.

## Publish

Private dataset publish commands:

```bash
harbor publish "evals/datasets/fx-release" -t "vX.Y.Z"
harbor publish "evals/datasets/fx-multistep" -t "vX.Y.Z"
```

Task-only publishing uses the task path:

```bash
harbor publish "evals/datasets/fx-release/create-file" -t "vX.Y.Z"
```

Use `--public` only when the release owner explicitly wants public registry visibility. Use `--no-tasks` only when tasks have already been published and the dataset manifest should reference existing task revisions.

## Visibility

Visibility can be checked or changed after publishing through Harbor Hub or the CLI:

```bash
harbor dataset visibility "vercel-labs-fx/fx-release" --private
harbor dataset visibility "vercel-labs-fx/fx-multistep" --private
harbor task visibility "vercel-labs-fx/create-file" --private
```

Private packages are visible only to members of the publishing org. Public packages are visible and runnable by everyone.

## Download

Use downloads to inspect a published package without changing local source:

```bash
harbor download "vercel-labs-fx/fx-release@vX.Y.Z" --output-dir evals/.build/downloads
harbor download "vercel-labs-fx/fx-multistep@vX.Y.Z" --output-dir evals/.build/downloads
```

Without `--output-dir`, Harbor downloads to its cache under `~/.cache/harbor`.

## Run By Reference

After publishing, run by registry reference instead of local path:

```bash
harbor run -d "vercel-labs-fx/fx-release@vX.Y.Z" -a "<agent>" -m "<model>"
harbor run -d "vercel-labs-fx/fx-multistep@vX.Y.Z" -a "<agent>" -m "<model>"
```

Local release signoff still uses `evals/jobs/*.yaml` and local Docker by default. Registry references are for sharing and post-publish validation.

## Do Not Publish

Never publish generated run output or host-local binaries:

- `evals/.build/`
- `evals/jobs-out/`
- `evals/images/fx`
- `evals/**/__pycache__/`
- `evals/**/*.pyc`
