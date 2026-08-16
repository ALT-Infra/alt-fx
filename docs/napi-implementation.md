# N-API implementation process

This is internal maintainer documentation for implementing, reviewing, testing, packaging, and releasing the native Node-API backend for `libfx`. It records the engineering process and ownership decisions behind the implementation. It is not consumer-facing API documentation.

For the exact runtime architecture, ABI, limits, error codes, and security invariants, read [`sdk/NAPI.md`](../sdk/NAPI.md). For supported public usage, read [`sdk/README.md`](../sdk/README.md).

## Goal and scope

The implementation adds a native Node backend for the headless fx agent while preserving the existing WebAssembly SDK and shared JavaScript API.

The intended outcome is:

- Node loads a platform-specific `.node` addon when available.
- Browser consumers continue to load the dependency-free WebAssembly SDK.
- Node can explicitly select `native`, `wasm`, or automatic fallback behavior.
- Both backends feed the same ACP client and event translation in `sdk/fx-sdk.js`.
- The native addon remains a narrow ACP byte transport, not a second agent implementation.
- Native execution does not implicitly grant native fx tools, MCP processes, filesystem access, command execution, or secret-store access.

The native surface is headless core only. The terminal remains WebAssembly-backed.

## Ownership map

Start changes in the module that owns the behavior:

| Concern | Owner |
| --- | --- |
| Native Node-API entry point, queues, lifecycle, fetch bridge | `src/napi_core_main.zig` |
| Shared host-driven Gateway streaming | `src/gateway/host_stream_provider.zig` |
| WebAssembly host transport adapter | `src/gateway/js_host_stream_provider.zig` |
| ACP callback transport and embedded configuration | `src/acp/`, `src/core/cli/acp_runner.zig` |
| Shared JavaScript agent and terminal behavior | `sdk/fx-sdk.js` |
| Node backend discovery and adaptation | `sdk/node.js` |
| Browser-only exports | `sdk/browser.js` |
| Build surfaces and optimization policy | `build.zig` |
| npm manifest and package assembly | `sdk/package.json`, `sdk/scripts/package-libfx.mjs` |
| CI and publishing | `.github/workflows/ci.yml`, `.github/workflows/publish-libfx.yml` |
| Native regression tests | `sdk/tests/test-native-core-*.mjs` |
| Cross-backend loader tests | `sdk/tests/test-libfx-loader.mjs`, `sdk/tests/test-node-*.mjs` |

Do not move product behavior into the addon or duplicate the ACP-to-JavaScript translation in `sdk/node.js`.

## Implementation sequence

The safest implementation order is contract-first. Each stage should compile and have focused coverage before advancing.

### 1. Define the embedded ACP boundary

The native addon needs to run the existing ACP server without owning process stdin or stdout and without reading process-global configuration.

The reusable boundary consists of:

- callback-backed ACP input and output;
- configuration overrides for credentials, home, workspace, and model;
- explicit capability switches for native tools and ACP MCP;
- lifecycle behavior that can terminate when the embedding host closes input.

The relevant shared changes are in:

- `src/acp/jsonrpc.zig` for callback output;
- `src/acp/server.zig` and `src/acp/sessions.zig` for transport/configuration composition;
- `src/acp/prompt.zig` for embedded prompt behavior;
- `src/core/cli/acp_runner.zig` for typed overrides and capability flags.

Keep native CLI defaults unchanged. Embedding restrictions must be explicit in the N-API composition rather than silently changing the ordinary `fx acp` server.

### 2. Extract the host-stream provider

WebAssembly already delegated Gateway HTTP streaming to JavaScript. Native Node needs the same trust boundary because Node must own `fetch`, cancellation, and response streaming.

The common provider lives in `src/gateway/host_stream_provider.zig`. It accepts a typed `Transport` with four operations:

- open a request;
- poll for response status;
- read the next response chunk;
- close the stream.

The provider owns request construction, Gateway headers, delivery state, status handling, SSE consumption, cooperative pulses, and cancellation mapping. Host adapters own only transport-specific mechanics.

`src/gateway/js_host_stream_provider.zig` is now a thin adapter over WebAssembly imports. `src/napi_core_main.zig` supplies the equivalent queue-backed transport for Node.

This extraction must preserve WebAssembly behavior. Build and test both WASM surfaces whenever the shared provider changes.

A non-obvious Zig constraint is that the WebAssembly provider is initialized at container scope. Its context must remain comptime-constructible. Do not replace the static provider context with runtime assignment during adapter creation.

### 3. Implement the native addon as a bounded transport

`src/napi_core_main.zig` is the native composition root. It should contain integration and boundary code, not duplicate agent behavior.

Each runtime contains:

- a bounded ACP input queue;
- a bounded ACP output queue;
- a bounded host-fetch bridge;
- one ACP worker thread;
- synchronization for queue access and destruction;
- copied, bounded runtime configuration;
- an atomic process-wide runtime slot reservation.

The worker thread runs `acp_server.runWithTransport()`. It never calls N-API. JavaScript invokes N-API on the Node thread to push ACP input, drain ACP output, take fetch requests, and publish fetch responses.

Keep the low-level export set small and versioned. The current ABI is documented in `sdk/NAPI.md`. Every exported operation must:

1. validate argument count and type before access;
2. verify the private `napi_type_tag` on runtime handles;
3. reject closed handles safely;
4. preserve JavaScript exceptions raised by property access;
5. return stable error codes where JavaScript branches on the failure class;
6. avoid holding queue locks while calling unrelated host operations.

Use a wrapped object and finalizer rather than exposing pointers or numeric handles. Explicit destruction and garbage collection must converge on the same idempotent path.

### 4. Design shutdown before the happy path

Thread and worker shutdown are the highest-risk part of the implementation. Establish these invariants before adding streaming features:

- destruction removes the runtime pointer before freeing anything;
- input is closed before joining the ACP thread;
- closing input wakes a blocked reader;
- shutting down wakes status waits, response reads, and backpressure waits;
- an active Node `fetch` receives an `AbortSignal` cancellation;
- Node worker termination can finalize an active stalled runtime without another JavaScript callback;
- repeated destruction is harmless;
- no allocation is freed while the worker thread may still reference it.

Test explicit close, abandoned-handle garbage collection, same-environment concurrency, worker isolation, and worker termination separately. A passing request/response test does not prove lifecycle safety.

### 5. Keep the native capability profile restrictive

Running native code is not permission to expose native fx capabilities. The N-API core composes ACP with:

- native tools disabled;
- ACP MCP disabled;
- background processes unavailable;
- secret store unavailable;
- list/read/command limits set to zero;
- only the host-backed Gateway stream enabled.

`home` and `workspaceRoot` provide session identity and context only. They are not filesystem capabilities.

Any future capability requires a typed host boundary, permission review, resource limits, cancellation behavior, and native security tests. Do not enable a shared native provider merely because it is easy to import.

### 6. Validate Gateway destinations twice

The JavaScript adapter and native addon both validate `FX_GATEWAY_CHAT_URL`.

Accepted destinations are:

- the canonical production Gateway URL; or
- explicit HTTP loopback on `127.0.0.1`, `localhost`, or `[::1]`, including a port.

Reject credentials, fragments, arbitrary HTTPS origins, non-loopback HTTP, and unsupported schemes. The duplicate check is intentional defense in depth because consumers can load `libfx.node` directly and bypass `sdk/node.js`.

Keep JavaScript, N-API, and shared streamable HTTP endpoint policy aligned.

### 7. Add the Node adapter without forking the SDK API

`sdk/node.js` is the Node-specific entry point. It imports the shared implementation from `sdk/fx-sdk.js` and supplies a native `runtimeFactory` when the addon is selected.

The runtime adapter must implement the same contract as the WASM runtime:

- `write(data)`;
- `closeStdin()`;
- `setLineHandler(handler)`;
- `exited`;
- `abortHostEffects()`;
- `abort()`.

The adapter polls native output and pending fetch work. It buffers ACP output to newline boundaries before JSON parsing. It performs Node `fetch` with an `AbortController`, sends status first, and streams response chunks under native backpressure.

Backend selection behavior is:

- `backend: "native"` requires a compatible native addon and fails closed;
- `backend: "wasm"` skips native discovery and requires JSPI;
- `backend: "auto"` prefers native and may fall back to WASM when JSPI is available.

Validate `libfxApiVersion` and required exports before use. Automatic discovery may load only the package's expected local addon names. Passing `nativeAddon` explicitly is an explicit request to execute that module.

Keep `sdk/browser.js` free of Node imports. Keep `sdk/fx-sdk.js` dependency-free and usable directly by browser consumers.

### 8. Add explicit build surfaces

`build.zig` exposes independent surface selectors:

```sh
zig build -Dwasm-surface=core
zig build -Dwasm-surface=term
zig build -Dnapi-surface=core
```

The output paths are:

- `zig-out/bin/fx-core.wasm`;
- `zig-out/bin/fx-term.wasm`;
- `zig-out/lib/libfx.node`.

Optimization policy is intentional:

- WASM forces `ReleaseSmall`, strips symbols, disables unnecessary frame/unwind/error-tracing features, and remains single-threaded.
- N-API forces `ReleaseSafe` and strips symbols. Safety checks remain enabled because the addon handles untrusted JavaScript and protocol input.
- The ordinary `fx` executable continues to use the standard optimization option.

The N-API build locates `node_api.h` from the active Node installation by default. Use `-Dnode-include-dir=<path>` when building against a nonstandard Node layout. Node resolves the addon's undefined N-API symbols at load time.

When merging build-system work, preserve unrelated selectors such as PGSO artifacts. A merge conflict near top-level enums can silently remove an independent build mode if resolved by choosing one side wholesale.

### 9. Package all supported native tuples atomically

The npm package contains:

- `browser.js`;
- `node.js`;
- `fx-sdk.js`;
- both WASM artifacts;
- one native addon for each supported tuple;
- `README.md` and `package.json`.

Supported native names are:

- `libfx.linux-x64.node`;
- `libfx.linux-arm64.node`;
- `libfx.darwin-x64.node`;
- `libfx.darwin-arm64.node`.

`package-libfx.mjs` rejects missing, duplicate, and unexpected platform artifacts for publishable assembly. The package has no runtime dependencies and no install script. Do not download or compile native code during consumer installation.

Validate the exact `npm pack --dry-run --json` file list before publishing. Packaging should copy already-built, already-tested artifacts and must not execute repository code in the publish job.

### 10. Separate build/test jobs from publication

`.github/workflows/publish-libfx.yml` builds each native addon on its matching native runner, runs the N-API lane there, and uploads a platform-named artifact. A separate WASM job builds both `ReleaseSmall` surfaces and runs the Node/WASM lane.

The publish job:

1. downloads the four native artifacts and both WASM artifacts;
2. checks the expected package manifest constraints;
3. stages an exact file allowlist;
4. sets the release-specific package version;
5. validates the npm archive contents;
6. checks that a dev publish still targets current `main`;
7. publishes with npm trusted publishing and provenance.

Stable publication is tied to the release tag for the exact commit. Dev versions include the workflow run and commit identity. Never assemble a package from artifacts built for different commits.

## Resource and security review

Before review, walk every value that crosses JavaScript, ACP, or fetch boundaries.

Verify:

- string lengths are checked before allocation;
- queue limits use overflow-safe subtraction;
- output and response backpressure cannot grow native memory without bound;
- runtime count is atomically limited;
- fake handles and use-after-close fail safely;
- malformed options release partially constructed state;
- URL policy is enforced before any request is handed to Node;
- API keys are neither logged nor serialized;
- no native tool or MCP advertisement leaks into initialization;
- cancellation wakes every possible blocking state;
- finalizers are safe during Node worker teardown.

The authoritative numeric limits and error-code table are in `sdk/NAPI.md`. Update that document and tests together whenever a contract changes.

## Test strategy

Use Node.js 24. JSPI-backed tests require `--experimental-wasm-jspi`, which the package scripts apply where needed.

### Focused development loop

For native-only changes:

```sh
zig fmt --check src/napi_core_main.zig src/gateway/host_stream_provider.zig
zig build -Dnapi-surface=core
npm run --prefix sdk test:node-napi
```

For shared loader or JavaScript adapter changes:

```sh
npm run --prefix sdk test:node-napi
npm run --prefix sdk test:node-wasm
```

For shared host-stream changes:

```sh
zig build -Dwasm-surface=core
zig build -Dwasm-surface=term
npm run --prefix sdk test:node-wasm
npm run --prefix sdk test:node-napi
```

For browser behavior:

```sh
npm run --prefix sdk test:browser-wasm
```

For terminal adapter changes:

```sh
npm ci --prefix sdk/node
npm run --prefix sdk/node test:term
```

### Full local proof for this surface

```sh
zig fmt --check build.zig src/gateway/host_stream_provider.zig \
  src/gateway/js_host_stream_provider.zig src/napi_core_main.zig
zig build test
zig build
./zig-out/bin/fx --version
zig build -Dwasm-surface=core
zig build -Dwasm-surface=term
zig build -Dnapi-surface=core
npm run --prefix sdk test:node-wasm
npm run --prefix sdk test:node-napi
npm run --prefix sdk test:browser-wasm
npm run --prefix sdk/node test:term
```

The native lane covers malformed input, resource limits, handle branding, backpressure, lifecycle, worker concurrency, security restrictions, ACP sessions, Gateway streaming, cancellation, and loader behavior.

A local pass is not the ship gate. Full CI must pass for the exact current commit on all required Linux and macOS runners, and the built CLI must be exercised locally before reporting the branch ready.

## Binary-size verification

Shared transport refactors can affect three artifact classes independently:

- the ordinary native `fx` executable;
- `fx-core.wasm` and `fx-term.wasm`;
- the new `libfx.node` addon.

Measure comparable builds from isolated source copies. Use the same compiler, target, optimization mode, source metadata, and build options. Compare both byte count and SHA-256 when checking for exact identity.

For the host-stream extraction in this implementation:

- the `ReleaseSafe` native `fx` executable was byte-for-byte identical before and after;
- `fx-core.wasm` increased by 441 bytes;
- `fx-term.wasm` increased by 465 bytes;
- the N-API addon had no pre-existing baseline because it was introduced by this work.

Do not compare a dirty incremental output against a clean build or compare artifacts with different embedded commit/version metadata.

## Patch and recovery workflow

Before a risky merge or broad conflict resolution:

1. inspect `git status --short --branch`;
2. create a recoverable copy that includes `.git`, staged changes, untracked files, and stashes;
3. exclude only generated caches and build outputs;
4. verify source and backup `HEAD` values match;
5. compare hashes of `git status --porcelain=v1 -z` from source and backup.

A suitable backup command is:

```sh
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dest="/tmp/fx-wasm-napi-backup-$stamp"
mkdir -p "$dest"
rsync -a --exclude '.zig-cache/' --exclude 'zig-out/' ./ "$dest/"
```

For an uncommitted feature branch, create a named stash, merge current `origin/main`, then reapply the stash. If `git stash pop --index` fails because upstream changed index context, confirm the stash remains intact and apply it without `--index`. Resolve content conflicts manually, stage the resolved files, and retain the safety stash until builds and tests pass.

When sharing a patch externally, generate it from the intended diff explicitly. For this branch that means the staged feature work plus the merge-base-to-branch committed changes as appropriate. Include a manifest with base commit, head commit, branch, status, file list, and checksums. Never include generated binaries, caches, credentials, or local configuration.

GitHub secret gists are unlisted, not strongly access-controlled. Anyone with the URL can read them. Use them only for code that is acceptable to expose to URL holders, and call the visibility model out when sharing the link.

## Common failure modes

### Container-scope provider is no longer comptime-known

Symptom: WASM compilation reports that a provider initializer cannot be evaluated at comptime.

Cause: the thin WebAssembly adapter mutates or constructs provider context at runtime even though the provider is stored in a container-level constant.

Fix: retain a static `ProviderContext` initialized from compile-time function pointers and return a provider referencing that context.

### Native tests pass but a worker hangs on termination

Cause: destruction waits for a native thread that is blocked in input, fetch status, response read, or response backpressure.

Fix: mark shutdown, close input, broadcast every relevant condition, abort host fetch, then join. Add or run the worker-termination regression directly.

### Native mode silently falls back

Cause: forced and automatic backend selection were conflated.

Fix: `backend: "native"` must surface addon load, version, export, or startup errors. Only automatic mode may fall back.

### Direct addon callers bypass URL policy

Cause: validation exists only in `sdk/node.js`.

Fix: keep equivalent validation in native code before exposing the request to Node.

### Package succeeds with one local addon

Cause: a development packaging path was reused for publication without enforcing the full platform matrix.

Fix: publish assembly must require exactly all four platform names and reject extras. A one-addon package is only a local development artifact.

### Main executable grows unexpectedly

Cause: shared N-API code became reachable from `src/main.zig`, or the comparison used different build metadata/options.

Fix: inspect the import graph, rebuild isolated trees with identical options, and compare hashes. N-API composition should remain rooted at `src/napi_core_main.zig`.

## Change checklist

Before landing N-API work:

1. Confirm the addon remains a transport around shared ACP behavior.
2. Confirm native capabilities remain disabled unless explicitly designed and reviewed.
3. Review every blocking wait and its shutdown wakeup.
4. Review every allocation and partial-construction cleanup path.
5. Keep JavaScript and native endpoint validation aligned.
6. Run native, Node/WASM, and browser/WASM lanes when shared code changes.
7. Build both WASM surfaces after host-stream changes.
8. Validate the exact package file allowlist and all native tuples.
9. Check formatting and `git diff --check`.
10. Exercise `./zig-out/bin/fx` so the ordinary product path is not regressed.
11. Require Full CI for the exact current commit before declaring the work ready.
12. Update `sdk/NAPI.md` for contract changes and `sdk/README.md` for supported public behavior changes.
