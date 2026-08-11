# 2026-05-05 Website Results Handoff

This is the source-of-truth data from the live Harbor comparison runs for Fx, Codex, Claude Code, and OpenCode.

Use the values marked as available. Do not infer or publish the values marked as not captured.

## Source Runs

| Suite | Harbor output dir | Harbor job id | Started | Finished | Wall-clock runtime |
| --- | --- | --- | --- | --- | --- |
| `fx-release` | `/Users/faxes/Developer/Fx/fx/evals/jobs-out/2026-05-05__02-16-55` | `f557f698-22fc-4ae7-8c96-3ab3da2ac97a` | `2026-05-05T02:16:55.309074` | `2026-05-05T03:50:30.681902` | `1h 33m 35s` |
| `terminal-bench/terminal-bench-2` smoke | `/Users/faxes/Developer/Fx/fx/evals/jobs-out/2026-05-05__03-52-21` | `eef1690e-71f6-42fa-a273-41c033f4c7d7` | `2026-05-05T03:52:23.365643` | `2026-05-05T04:24:04.769849` | `31m 41s` |

Generated report in repo:

`/Users/faxes/Developer/Fx/fx/evals/runs/2026-05-05-comparison-signoff-fixed.md`

## Models And Effort

| Agent | Model used | Effort / thinking setting | Notes |
| --- | --- | --- | --- |
| Fx | `anthropic/claude-opus-4.7` | `high` | Run through the built `fx` binary wrapper. |
| Codex | `openai/gpt-5.5` | `high` | Run through Codex CLI with local auth upload into the Harbor container. |
| Claude Code | `anthropic/claude-opus-4.7` | `high` | Run through Claude Code with Vercel AI Gateway env and container-local config. |
| OpenCode | `openai/anthropic/claude-sonnet-4.6` | `--thinking` | OpenCode did not run Opus in this comparison; it ran Sonnet 4.6 through the OpenAI-compatible AI Gateway path. |

## Combined Leaderboard

Combined means 6 `fx-release` tasks plus 1 Terminal-Bench smoke task, 7 scored tasks per agent.

| Rank | Agent | Model | Record | Pass rate | Mean reward | Gap vs leaders | Agent execution runtime |
| ---: | --- | --- | ---: | ---: | ---: | --- | ---: |
| 1 | Codex | `openai/gpt-5.5` | `7-0` | `100%` | `1.00` | `tied` | `18m 55s` |
| 1 | Claude Code | `anthropic/claude-opus-4.7` | `7-0` | `100%` | `1.00` | `tied` | `8m 35s` |
| 3 | Fx | `anthropic/claude-opus-4.7` | `6-1` | `86%` | `0.86` | `-14 pp vs leaders` | `11m 07s` |
| 4 | OpenCode | `openai/anthropic/claude-sonnet-4.6` | `4-3` | `57%` | `0.57` | `-43 pp vs leaders` | `17m 43s` |

Runtime above is summed agent execution time from Harbor trial result JSON. It does not include agent install/setup, environment setup, verifier time, or artifact collection.

## Per-Suite Results

### fx-release

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Agent execution runtime |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fx | `anthropic/claude-opus-4.7` | 6 | 6 | `1.00` | `1.00` | 0 | 0 | `6m 35s` |
| Codex | `openai/gpt-5.5` | 6 | 6 | `1.00` | `1.00` | 0 | 0 | `10m 16s` |
| Claude Code | `anthropic/claude-opus-4.7` | 6 | 6 | `1.00` | `1.00` | 0 | 0 | `6m 32s` |
| OpenCode | `openai/anthropic/claude-sonnet-4.6` | 6 | 4 | `0.67` | `0.67` | 2 | 0 | `16m 14s` |

### Terminal-Bench Smoke

Only the smoke task was run. Full Terminal-Bench was not run.

| Agent | Model | n_trials | n_passed | pass_rate | mean_reward | exceptions | artifact failures | Agent execution runtime |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fx | `anthropic/claude-opus-4.7` | 1 | 0 | `0.00` | `0.00` | 0 | 0 | `4m 32s` |
| Codex | `openai/gpt-5.5` | 1 | 1 | `1.00` | `1.00` | 0 | 0 | `8m 39s` |
| Claude Code | `anthropic/claude-opus-4.7` | 1 | 1 | `1.00` | `1.00` | 0 | 0 | `2m 03s` |
| OpenCode | `openai/anthropic/claude-sonnet-4.6` | 1 | 0 | `0.00` | `0.00` | 0 | 0 | `1m 29s` |

## Task Outcome Matrix

### fx-release Tasks

| Task | Fx | Codex | Claude Code | OpenCode |
| --- | --- | --- | --- | --- |
| `create-file` | pass | pass | pass | pass |
| `cli-with-tests` | pass | pass | pass | fail, timeout after 360s |
| `run-command` | pass | pass | pass | pass |
| `crud-api` | pass | pass | pass | fail, timeout after 420s |
| `edit-file` | pass | pass | pass | pass |
| `grep-files` | pass | pass | pass | pass |

### Terminal-Bench Smoke Task

| Task | Fx | Codex | Claude Code | OpenCode |
| --- | --- | --- | --- | --- |
| `break-filter-js-from-html` | fail | pass | pass | fail |

## Exceptions

| Suite | Agent | Task | Exception |
| --- | --- | --- | --- |
| `fx-release` | OpenCode | `cli-with-tests` | `harbor.trial.trial.AgentTimeoutError: Agent execution timed out after 360.0 seconds` |
| `fx-release` | OpenCode | `crud-api` | `harbor.trial.trial.AgentTimeoutError: Agent execution timed out after 420.0 seconds` |

No exceptions occurred in the Terminal-Bench smoke run.

## Artifact Collection

| Suite | Artifact collection failures |
| --- | ---: |
| `fx-release` | 0 |
| Terminal-Bench smoke | 0 |

The earlier expected `/tmp/fx-home/.fx` artifact warnings were fixed before this run. These final runs had no artifact collection failures.

## Auth And Host Config Scope

| Item | Status |
| --- | --- |
| `AI_GATEWAY_API_KEY` | Required and used for gateway-backed agents. Secret value is not printed here. |
| Codex auth upload | Worked. Logs show `CODEX_AUTH_JSON_PATH` was used and auth was linked inside container-local `CODEX_HOME`. Secret contents were not printed. |
| Host Codex config writes | Not observed from the comparison wrappers. Codex used container-local `CODEX_HOME` plus `/tmp/codex-secrets`. |
| Host Claude config writes | Not observed from the comparison wrappers. Claude used container-local `CLAUDE_CONFIG_DIR=/tmp/claude-code-config`. |
| Host OpenCode config writes | Not observed from the comparison wrappers. OpenCode config/auth was written under the Harbor task container home. |

## Efficiency Data Availability

Use this section carefully. Token and cost capture was not uniform across agents.

| Agent | Agent execution runtime | Tokens in | Cached tokens | Tokens out | Captured total cost | Cost per pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Fx | `11m 07s` | not captured | not captured | not captured | not captured | not captured |
| Codex | `18m 55s` | `1,628,940` | `1,551,616` | `17,172` | partial only: `$0.721403` captured for smoke, release cost not captured | not reliable |
| Claude Code | `8m 35s` | `1,654,503` | `1,383,540` | `14,757` | `$8.262375` | `$1.18` |
| OpenCode | `17m 43s` | `712,433` | not captured | `10,318` | not captured | not captured |

Do not publish cost-per-pass as a cross-agent comparison from this run. Harbor only captured complete cost for Claude Code, partial cost for Codex, and no cost for Fx or OpenCode.

## Website Schema Mapping

### `meta`

Available:

```ts
meta: {
  slug: "comparison-signoff-fixed",
  version: "v0.3.2",
  label: "comparison signoff fixed",
  date: "2026-05-05",
  runId: "f557f698 + eef1690e",
}
```

Do not set `current: true` unless this run is intended to become the active website result.

### `hero`

Available values:

```ts
hero: {
  eyebrow: "Harbor live comparison / fx-release + Terminal-Bench smoke",
  title: "Fx ties the leaders on release evals, then falls behind on the deeper smoke task.",
  summary: "Across the six fx-release tasks, **Fx, Codex, and Claude Code all scored 6/6**. Adding the Terminal-Bench smoke task separates the field: **Codex and Claude Code finish 7-0**, **Fx finishes 6-1**, and **OpenCode finishes 4-3**.",
  meta: [
    { label: "Run", value: "comparison-signoff-fixed" },
    { label: "Date", value: "2026-05-05" },
    { label: "Suite", value: "fx-release + Terminal-Bench smoke" },
    { label: "Tasks", value: "7 scored tasks per agent" },
    { label: "Status", value: "completed" },
  ],
}
```

### `kpi`

Available values:

```ts
kpi: [
  { label: "Fx release pass rate", value: "100%", delta: "6/6 on fx-release", deltaTone: "positive" },
  { label: "Fx combined pass rate", value: "86%", delta: "6/7 across release + smoke", deltaTone: "neutral" },
  { label: "Leaders", value: "100%", delta: "Codex and Claude Code both 7/7", deltaTone: "positive" },
  { label: "Artifact failures", value: "0", delta: "No collection failures in final runs", deltaTone: "positive" },
]
```

### `cliStanding.rows`

Available values:

```ts
[
  {
    name: "Codex",
    initials: "C",
    model: "gpt-5.5, high reasoning",
    logo: "openai-logo",
    passPct: 100,
    record: "7-0",
    gap: "tied",
    runtime: "18m 55s agent execution",
    costPerPass: "not reliable",
  },
  {
    name: "Claude Code",
    initials: "CC",
    model: "claude-opus-4.7, high effort",
    logo: "anthropic-logo",
    passPct: 100,
    record: "7-0",
    gap: "tied",
    runtime: "8m 35s agent execution",
    costPerPass: "$1.18 captured",
  },
  {
    name: "Fx",
    initials: "FX",
    model: "claude-opus-4.7, high effort",
    logo: "vercel",
    passPct: 86,
    record: "6-1",
    gap: "-14 pp vs leaders",
    runtime: "11m 07s agent execution",
    costPerPass: "not captured",
    isFx: true,
  },
  {
    name: "OpenCode",
    initials: "OC",
    model: "claude-sonnet-4.6 via AI Gateway",
    passPct: 57,
    record: "4-3",
    gap: "-43 pp vs leaders",
    runtime: "17m 43s agent execution",
    costPerPass: "not captured",
  },
]
```

Note: OpenCode has no logo in the current logo list, so use initials fallback unless a logo is added.

### `taskOutcomes`

Available task outcome cells:

```ts
agents: ["Fx", "Codex", "Claude Code", "OpenCode"],
rows: [
  { task: "fx-release/create-file", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "pass" }] },
  { task: "fx-release/cli-with-tests", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "fail", note: "AgentTimeoutError after 360s" }] },
  { task: "fx-release/run-command", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "pass" }] },
  { task: "fx-release/crud-api", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "fail", note: "AgentTimeoutError after 420s" }] },
  { task: "fx-release/edit-file", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "pass" }] },
  { task: "fx-release/grep-files", cells: [{ status: "pass" }, { status: "pass" }, { status: "pass" }, { status: "pass" }] },
  { task: "terminal-bench-smoke/break-filter-js-from-html", cells: [{ status: "fail" }, { status: "pass" }, { status: "pass" }, { status: "fail" }] },
]
```

Suggested summary callouts:

```ts
summary: [
  {
    label: "Release evals",
    body: "Fx, Codex, and Claude Code all passed every fx-release task. OpenCode passed four and timed out on two larger tasks.",
  },
  {
    label: "Deeper smoke task",
    body: "Codex and Claude Code solved the Terminal-Bench smoke task. Fx and OpenCode did not.",
  },
  {
    label: "Harness quality",
    body: "Final runs had zero artifact collection failures and no Claude/OpenCode setup failures.",
  },
]
```

### `efficiency`

Only use this if the UI can clearly show missing values.

```ts
efficiency: {
  note: "Runtime is summed Harbor agent execution time only. Cost and token capture was not uniform across agents.",
  rows: [
    {
      name: "Codex",
      initials: "C",
      model: "gpt-5.5, high reasoning",
      logo: "openai-logo",
      runtime: "18m 55s",
      tokensIn: "1,628,940",
      tokensOut: "17,172",
      total: "partial only",
      perPass: "not reliable",
    },
    {
      name: "Claude Code",
      initials: "CC",
      model: "claude-opus-4.7, high effort",
      logo: "anthropic-logo",
      runtime: "8m 35s",
      tokensIn: "1,654,503",
      tokensOut: "14,757",
      total: "$8.262375",
      perPass: "$1.18",
    },
    {
      name: "Fx",
      initials: "FX",
      model: "claude-opus-4.7, high effort",
      logo: "vercel",
      runtime: "11m 07s",
      tokensIn: "not captured",
      tokensOut: "not captured",
      total: "not captured",
      perPass: "not captured",
      isFx: true,
    },
    {
      name: "OpenCode",
      initials: "OC",
      model: "claude-sonnet-4.6 via AI Gateway",
      runtime: "17m 43s",
      tokensIn: "712,433",
      tokensOut: "10,318",
      total: "not captured",
      perPass: "not captured",
    },
  ],
}
```

## Information Not Available From These Runs

Do not publish or imply these:

- Full Terminal-Bench performance. Only `--smoke` ran, with one Terminal-Bench task.
- Multi-run variance, confidence intervals, or statistical significance. Each task was run once per agent.
- Complete cross-agent cost comparison. Cost capture is incomplete.
- Complete cross-agent token comparison. Fx token usage was not captured.
- OpenCode Opus 4.7 performance. OpenCode ran `anthropic/claude-sonnet-4.6`, not Opus 4.7.
- Any result for Anomaly or other agents not listed above.
- Runtime including setup/install/verifier/artifact collection per agent. The per-agent runtime values here are agent execution only.
- A claim that Fx beats Codex or Claude Code overall. It ties them on `fx-release`, but loses the Terminal-Bench smoke task.
- A claim that Fx failed release readiness. Fx passed all six `fx-release` comparison tasks.

## Plain-English Read

Fx is strong on the project-local release evals: it went 6/6, tied with Codex and Claude Code, and beat OpenCode.

The deeper smoke task changes the story. Codex and Claude Code solved `break-filter-js-from-html`; Fx and OpenCode did not. So the accurate public framing is:

> Fx is release-eval competitive with Codex and Claude Code on this suite, but the external Terminal-Bench smoke result shows there is still a gap on harder agentic tasks.

