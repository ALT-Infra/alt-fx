# macOS arm64 PGSO candidate pipeline

This directory owns the non-publishing Stage 1 build for a smaller macOS arm64 `fx` candidate. It preserves Zig ReleaseSafe semantics and the complete product feature set, then uses native LLVM profiles to keep measured hot code speed-oriented and compile profile-proven cold functions for size.

The candidate is accepted only when it is no larger than **7.800 MiB**, has the preferred **0.250 MiB** of size headroom, passes the deterministic product corpus, and stays within a **10%** p50 and p95 performance regression limit. The ordinary ReleaseSafe binary remains the control and recovery path.

## Toolchain and target

The driver fails unless all of these match exactly:

- macOS on an arm64 host
- generic `aarch64-macos` output
- Zig `0.16.0`
- LLVM `21.1.8` tools and profile runtime from one configured LLVM root
- the selected source commit, update channel, bitcode hash, corpus hash, and profile-generation flags

The pipeline does not use the host CPU as the release target. The final candidate must match the control's architecture and minimum macOS version, contain a valid code signature, contain no profile sections or profile-runtime dependency, and produce no profile output when executed.

## Commands

Every mutating command requires a fresh or empty output directory. State from separate runs is never merged implicitly.

```bash
python3 -m scripts.pgso build \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-build

python3 -m scripts.pgso train \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-train

python3 -m scripts.pgso all \
  --llvm-bin "$(brew --prefix llvm@21)/bin" \
  --output-dir /tmp/fx-pgso-candidate \
  --target aarch64-macos \
  --update-channel stable \
  --samples 50
```

`build` verifies the control, bitcode, instrumented link, profile-section alignment, signature, and one profile-producing smoke. `train` additionally runs the versioned corpus and creates a checked candidate. Both are useful diagnostics but finish with `eligible: false` because they do not run the complete release-safety gate.

`qualify` and `all` run the complete fresh-build path: training, profile use, candidate verification, the candidate behavior corpus, six startup comparisons, and six heavy-workload comparisons. `all` is the canonical CI entry point. `report --output-dir <path>` is the only command that may reuse an existing directory, and it only reads a complete eligible manifest.

## Corpus

[`corpus.json`](corpus.json) references existing test owners instead of copying their behavior. It contains six direct CLI commands and thirty deterministic E2E files covering CLI, configuration, tools, Gateway lifecycle, fake web and vision routes, ACP, modern and legacy MCP, sessions, terminal hosting, TUI startup, resizing, rendering, permissions, interruption, subagents, and recovery.

Sound-bearing `notifications.test.ts` and `tui-command-permissions.test.ts` are explicitly excluded. Live-model and live-network files are forbidden. Corpus processes receive an isolated home and tmux socket and cannot inherit model credentials, the caller's tmux session, or an external LLVM profile destination.

Each training scenario must create a new nonempty raw profile. The driver merges that batch into the accumulator atomically, deletes only the successfully merged raw files, and stops before profile use on any missing scenario, timeout, warning, merge failure, or cleanup failure.

## Qualification policy

Startup compares `help`, `--version`, `status --json`, `background --json`, `doctor --json`, and `sessions --json`. Heavy qualification compares file indexing at 100,000 paths, UI activity, and approval transcript, diff, combined, and large-payload workloads.

Every comparison uses at least 50 measured samples for each artifact. Pair order alternates AB then BA to balance ordering effects. Command failures and timeouts count as failed samples and are never replaced. A candidate fails when either p50 or p95 is more than 10% slower than its matching control. The existing Linux startup workflow remains the authority for the repository's absolute 2 ms command budget.

## Output and failure behavior

The output root contains:

```text
control/bin/fx
instrumented/fx
candidate/fx
profiles/merged.profdata
logs/
measurements/
manifest.json
```

Generated binaries, bitcode, objects, profiles, caches, measurements, and logs are evidence artifacts and must not be committed. `manifest.json` is rewritten atomically after every stage. A failed manifest retains completed evidence, names the failing stage, records `eligible: false`, and never falls back to an unprofiled candidate.

The native workflow uploads this directory for inspection. It has read-only repository permissions and does not change release, dev-channel, CDN, tag, or GitHub Release state.
