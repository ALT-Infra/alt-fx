# macOS arm64 PGSO candidate pipeline

This directory owns the non-publishing Stage 1 build for a smaller macOS arm64 `fx` candidate. It preserves Zig ReleaseSafe semantics and the complete product feature set, then uses native LLVM profiles to keep measured hot code speed-oriented and compile profile-proven cold functions for size.

The candidate is accepted only when it is no larger than **7.800 MiB**, has the preferred **0.250 MiB** of size headroom, passes the deterministic product corpus, and stays within a **10%** p50 and p95 performance regression limit. The ordinary ReleaseSafe binary remains the control and recovery path.

## Toolchain and target

The driver fails unless all of these match exactly:

- macOS on an arm64 host
- generic `aarch64-macos` output
- Zig `0.16.0`
- LLVM `21.1.8` tools and profile runtime from one configured LLVM root
- Bun `1.3.14`
- Hyperfine `1.20.0`
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

Sound-bearing `notifications.test.ts` and `tui-command-permissions.test.ts` are explicitly excluded. The credential-dependent `tui-agent.test.ts` suite is replaced by deterministic fake-Gateway permission-error coverage. Live-model and live-network files are forbidden. Corpus processes receive per-scenario homes and isolated tmux sockets and cannot inherit model credentials, the caller's tmux session, an external LLVM profile destination, or caller-selected fx tracing. The CLI and MCP authentication suites explicitly link the host Keychains directory into only their scenario homes so their uniquely named fake macOS Keychain assertions can run; no other scenario receives that access.

Each training scenario must create a new nonempty raw profile. The driver merges that batch into the accumulator atomically, deletes only the successfully merged raw files, and stops before profile use on any missing scenario, timeout, warning, merge failure, or cleanup failure.

Candidate behavior qualification records each scenario's debug trace under `candidate-behavior/traces/` without restricting its trace scopes. A failed tmux case therefore preserves its internal startup subtype and cleanup evidence instead of retaining only the public protocol error, while tests that select their own trace path or scopes keep their intended behavior.

## Qualification policy

Startup compares `help`, `--version`, `status --json`, `background --json`, `doctor --json`, and `sessions --json`. It first executes each verified immutable artifact once to require successful output and empty stderr. Timing then uses pinned Hyperfine with no intermediate shell, ten warmups per artifact in each of ten rounds, at least 100 measured samples per artifact, and alternating control-then-candidate and candidate-then-control order. Limiting the default contiguous block to ten measured runs spreads short machine-noise bursts across both artifacts. Startup measurement sets `FX_DISABLE_KEYCHAIN=1` so the compiler comparison cannot be dominated by host-global macOS Keychain subprocess latency; the deterministic behavior corpus remains responsible for exercising Keychain integration. No per-sample Python process management or evidence-file write is included in the timed boundary, and measurement never replaces `zig-out/bin/fx`. Heavy qualification compares file indexing at 100,000 paths, UI activity, and approval transcript, diff, combined, and large-payload workloads.

Heavy comparisons use at least 50 measured samples for each artifact and alternate pair order AB then BA. Command failures and timeouts fail qualification and are never replaced. A candidate fails when either p50 or p95 is more than 10% slower than its matching control. The existing Linux startup workflow remains the authority for the repository's absolute 2 ms command budget.

## Output and failure behavior

The output root contains:

```text
control/bin/fx
instrumented/fx
candidate/fx
profiles/merged.profdata
candidate-behavior/traces/
logs/
measurements/
manifest.json
```

Generated binaries, bitcode, objects, profiles, caches, measurements, and logs are evidence artifacts and must not be committed. `manifest.json` is rewritten atomically after every stage. A failed manifest retains completed evidence, names the failing stage, records `eligible: false`, and never falls back to an unprofiled candidate.

The native workflow uploads this directory for inspection. It has read-only repository permissions and does not change release, dev-channel, CDN, tag, or GitHub Release state.
