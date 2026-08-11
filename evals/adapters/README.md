# fx Harbor Adapter Notes

This folder documents how future `tests/evals` Bun scenarios should be ported into Harbor task directories.

Docs used for this adapter scaffold:

- https://www.harborframework.com/docs/datasets/adapters
- https://www.harborframework.com/docs/datasets/adapters-human
- https://www.harborframework.com/docs/tasks
- https://www.harborframework.com/docs/tasks/task-difference
- https://www.harborframework.com/docs/tasks/task-tutorial
- https://www.harborframework.com/docs/migration
- https://www.harborframework.com/docs/tasks/windows-container-support

## Current Support

There is no automatic converter in this slice. The Bun eval files under `tests/evals` combine prompt setup, fixture setup, runner behavior, and judge assertions through TypeScript helpers, so the supported path is manual porting into explicit Harbor tasks.

Supported validation command for the manually ported local tasks:

```bash
./evals/scripts/check-local-tasks.sh
```

That command expects `fx-evals:local` to exist, builds each local Harbor task image, runs the checked-in oracle solution, then runs the verifier and requires `/logs/verifier/reward.txt` to contain `1`.

## Future Adapter CLI Shape

If a converter is added, its command line must match the Harbor adapter contract:

```bash
uv run python -m fx_bun_adapter.main --output-dir evals/datasets/fx-bun
uv run python -m fx_bun_adapter.main --output-dir evals/datasets/fx-bun --limit 5
uv run python -m fx_bun_adapter.main --output-dir evals/datasets/fx-bun --task-ids create-file,run-command
uv run python -m fx_bun_adapter.main --output-dir evals/datasets/fx-bun --overwrite
```

Flag semantics:

- `--output-dir`: required destination for generated Harbor task directories.
- `--limit`: optional maximum number of tasks to emit after `--task-ids` filtering.
- `--overwrite`: replace existing generated task directories. Without it, existing directories must be preserved and reported as an error.
- `--task-ids`: comma-separated upstream task ids, using the `tests/evals/<task-id>.test.ts` file stem. Generated Harbor task names should be `vercel-labs-fx/<task-id>`.

## Manual Porting Checklist

For each Bun eval chosen for Harbor:

1. Convert the user-facing prompt into `instruction.md`. Include the expected output paths and constraints, but not oracle answers.
2. Put deterministic environment setup in `environment/Dockerfile` or step `workdir/` files.
3. Put the oracle in `solution/solve.sh` for single-step tasks, or under each `steps/<name>/solution/solve.sh` for multi-step tasks.
4. Put verifier logic in `tests/test.sh` or `steps/<name>/tests/test.sh`.
5. Always write `/logs/verifier/reward.txt` with a numeric reward on bad-solution paths.
6. Prefer absolute paths in verifiers.
7. Keep generated tasks Linux-targeted unless a source eval explicitly needs Windows container behavior. Windows tasks require `[environment].os = "windows"` plus `.bat` entrypoints.
8. Keep adapter parity and comparison work manual until the TypeScript helpers have a stable metadata format that can be converted without guessing.
