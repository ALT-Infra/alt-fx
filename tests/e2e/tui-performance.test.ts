import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { readTapeFrames, type TapeFrame } from "./render-lab/tape";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const ENABLED = process.env.FX_TUI_PERFORMANCE === "1";
const LIVE_ENABLED = process.env.FX_E2E_REAL_API === "1" &&
  typeof process.env.AI_GATEWAY_API_KEY === "string" &&
  process.env.AI_GATEWAY_API_KEY.length > 0;
const WARMUPS = 5;
const SAMPLES = 50;
const BUDGETS_MS = { p50: 4, p90: 8, p95: 16 } as const;
const TIMEOUT = 60_000;

type Samples = {
  firstPaint: number[];
  contentReady: number[];
};

type ResourceSnapshot = {
  rssKib: number;
  threads: number;
  descriptors: number;
};

function percentile(values: readonly number[], fraction: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
}

function summary(values: readonly number[]) {
  return {
    count: values.length,
    p50: percentile(values, 0.5),
    p90: percentile(values, 0.9),
    p95: percentile(values, 0.95),
    max: Math.max(...values),
    failures: 0,
  };
}

function readCompleteTape(path: string): TapeFrame[] {
  let lastError: unknown;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      return readTapeFrames(path);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

function frameLatency(
  frames: readonly TapeFrame[],
  fromIndex: number,
  contentMarker?: string,
): { firstPaint: number; contentReady: number } {
  const inputIndex = frames.findIndex((frame, index) =>
    index >= fromIndex && frame.kind === 2
  );
  if (inputIndex < 0) throw new Error("recording did not contain the measured stdin frame");

  let elapsed = 0;
  let firstPaint: number | undefined;
  let lastPaint: number | undefined;
  let output = "";
  for (let index = inputIndex + 1; index < frames.length; index += 1) {
    const frame = frames[index]!;
    elapsed += frame.deltaMs;
    if (frame.kind === 2) break;
    if (frame.kind !== 1) continue;
    firstPaint ??= elapsed;
    lastPaint = elapsed;
    output += frame.payload.toString("utf8");
    if (contentMarker === undefined || output.includes(contentMarker)) {
      return { firstPaint, contentReady: elapsed };
    }
  }
  if (firstPaint !== undefined && lastPaint !== undefined) {
    return { firstPaint, contentReady: lastPaint };
  }
  throw new Error(
    `recording did not contain content-ready stdout after input; marker=${JSON.stringify(contentMarker)}`,
  );
}

async function measureAction(
  tapePath: string,
  action: () => void,
  waitReady: () => Promise<unknown>,
  contentMarker?: string,
): Promise<{ firstPaint: number; contentReady: number }> {
  const fromIndex = readCompleteTape(tapePath).length;
  action();
  await waitReady();
  return frameLatency(readCompleteTape(tapePath), fromIndex, contentMarker);
}

function appendMeasured(samples: Samples, value: { firstPaint: number; contentReady: number }) {
  samples.firstPaint.push(value.firstPaint);
  samples.contentReady.push(value.contentReady);
}

function resourceSnapshot(pid: number): ResourceSnapshot {
  const rssKib = Number.parseInt(
    execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim(),
    10,
  );
  const threads = process.platform === "linux"
    ? Number.parseInt(
      readFileSync(`/proc/${pid}/status`, "utf8").match(/^Threads:\s+(\d+)$/m)?.[1] ?? "0",
      10,
    )
    : execFileSync("ps", ["-M", "-p", String(pid)], { encoding: "utf8" })
      .trim().split("\n").length - 1;
  const descriptors = process.platform === "linux"
    ? readdirSync(`/proc/${pid}/fd`).length
    : execFileSync("lsof", ["-p", String(pid), "-Fn"], { encoding: "utf8" })
      .split("\n").filter((line) => line.startsWith("n")).length;
  return { rssKib, threads, descriptors };
}

function longTranscript(): string {
  const rows: string[] = [];
  for (let index = 0; index < 2_100; index += 1) {
    if (index === 0) rows.push("PERF_TRANSCRIPT_HEAD");
    else if (index === 1_050) rows.push("PERF_TRANSCRIPT_MIDDLE");
    else if (index === 2_099) rows.push("PERF_TRANSCRIPT_TAIL");
    else if (index % 17 === 0) rows.push(`| ${index} | wide unicode 𝒇x 漢字 | wrapped ${"x".repeat(96)} |`);
    else if (index % 11 === 0) rows.push("");
    else rows.push(`transcript row ${String(index).padStart(4, "0")}`);
  }
  return rows.join("\n");
}

function createFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-performance-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const skillsRoot = join(workspace, ".agents", "skills");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(skillsRoot, { recursive: true });
  const hash = createHash("sha256");
  for (let index = 0; index < 289; index += 1) {
    const name = index % 2 === 0
      ? `needle-skill-${String(index).padStart(3, "0")}`
      : `other-skill-${String(index).padStart(3, "0")}`;
    const body = `---\nname: ${name}\ndescription: performance fixture ${index}\n---\nbody ${index}\n`;
    const dir = join(skillsRoot, name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "SKILL.md"), body);
    hash.update(body);
  }
  const transcript = longTranscript();
  hash.update(transcript);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tapePath: join(root, "performance.fxtape"),
    stderrPath: join(root, "stderr.log"),
    fixtureHash: hash.digest("hex"),
    transcript,
  };
}

test.skipIf(!ENABLED || !tmuxAvailable())(
  "interactive terminal surfaces stay within one frame at p95",
  async () => {
    const fixture = createFixture();
    const gateway = startFakeGateway([fakeGatewayFinalText(fixture.transcript)]);
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-performance-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_RECORD: fixture.tapePath,
          FX_RECORD_INPUT: "1",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
        minimumHistoryLines: 20_000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Build the performance transcript.");
      await session.waitForText("PERF_TRANSCRIPT_TAIL", TIMEOUT);

      // One correctness cycle also fences the inline prewarm before timing.
      session.sendKeysImmediate(["C-o"]);
      await session.waitForText("Full detail · ctrl o close", TIMEOUT);
      expect(await session.captureFullScrollback()).toContain("PERF_TRANSCRIPT_HEAD");
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      const samples = {
        fullOpen: { firstPaint: [], contentReady: [] } as Samples,
        fullScroll: { firstPaint: [], contentReady: [] } as Samples,
        skillsOpen: { firstPaint: [], contentReady: [] } as Samples,
        skillsQuery: { firstPaint: [], contentReady: [] } as Samples,
        loginOpen: { firstPaint: [], contentReady: [] } as Samples,
      };
      const pid = session.processPid();
      const resourcesBefore = resourceSnapshot(pid);

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["C-o"]),
          () => session!.waitForText("Full detail · ctrl o close", TIMEOUT),
          "Full detail",
        );
        const scroll = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["Up"]),
          async () => {
            await Bun.sleep(25);
          },
        );
        session.sendKeysImmediate(["Escape"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) {
          appendMeasured(samples.fullOpen, open);
          appendMeasured(samples.fullScroll, scroll);
        }
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        await session.sendLiteralText("/skills");
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["Enter"]),
          () => session!.waitForText("Skills 289", TIMEOUT),
          "Skills 289",
        );
        const query = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("needle"),
          () => session!.waitForText("Skills 145", TIMEOUT),
          "Skills 145",
        );
        session.sendKeysImmediate(["Escape"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) {
          appendMeasured(samples.skillsOpen, open);
          appendMeasured(samples.skillsQuery, query);
        }
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        session.sendKeysImmediate(["C-u"]);
        await session.waitForComposer(TIMEOUT);
        await session.sendLiteralText("/login");
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["Enter"]),
          () => session!.waitForText("Connections", TIMEOUT),
          "Connections",
        );
        session.sendKeysImmediate(["Escape"]);
        await session.waitForComposer(TIMEOUT);
        session.sendKeysImmediate(["C-u"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) appendMeasured(samples.loginOpen, open);
      }

      await Bun.sleep(250);
      const resourcesAfter = resourceSnapshot(pid);
      const report = {
        boundary: "recorded application stdin frame to recorded stdout frame",
        buildMode: "ReleaseSafe",
        warmups: WARMUPS,
        measuredSamples: SAMPLES,
        terminal: { cols: 104, rows: 30 },
        fixture: {
          hash: fixture.fixtureHash,
          skills: 289,
          transcriptLines: 2_100,
          transcriptBytes: Buffer.byteLength(fixture.transcript),
        },
        budgetsMs: BUDGETS_MS,
        results: Object.fromEntries(
          Object.entries(samples).map(([name, values]) => [name, {
            firstPaint: summary(values.firstPaint),
            contentReady: summary(values.contentReady),
          }]),
        ),
        resources: { before: resourcesBefore, after: resourcesAfter },
      };
      const reportPath = process.env.FX_TUI_PERFORMANCE_REPORT;
      if (reportPath) writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

      for (const values of Object.values(samples)) {
        for (const distribution of [values.firstPaint, values.contentReady]) {
          const measured = summary(distribution);
          expect(measured.count).toBe(SAMPLES);
          expect(measured.p50).toBeLessThanOrEqual(BUDGETS_MS.p50);
          expect(measured.p90).toBeLessThanOrEqual(BUDGETS_MS.p90);
          expect(measured.p95).toBeLessThanOrEqual(BUDGETS_MS.p95);
        }
      }
      expect(resourcesAfter.threads).toBe(resourcesBefore.threads);
      expect(resourcesAfter.descriptors).toBe(resourcesBefore.descriptors);
      expect(resourcesAfter.rssKib - resourcesBefore.rssKib).toBeLessThan(16 * 1024);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      gateway.stop();
      if (process.env.FX_TUI_PERFORMANCE_KEEP !== "1") {
        rmSync(fixture.root, { recursive: true, force: true });
      } else {
        console.error(`retained TUI performance fixture at ${fixture.root}`);
      }
    }
  },
  300_000,
);

test.skipIf(!LIVE_ENABLED || !tmuxAvailable())(
  "live provider preserves the fast menu and prepared transcript pipeline",
  async () => {
    const fixture = createFixture();
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
          VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
        minimumHistoryLines: 20_000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText(
        "Write 120 short numbered lines, then write LIVE_PERFORMANCE_DONE on its own line.",
      );
      await session.waitForText("LIVE_PERFORMANCE_DONE", TIMEOUT);

      session.sendKeysImmediate(["C-o"]);
      await session.waitForText("Full detail · ctrl o close", TIMEOUT);
      session.sendKeysImmediate(["Up"]);
      await Bun.sleep(25);
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      await session.sendText("/skills");
      await session.waitForText("Skills 289", TIMEOUT);
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      session.sendKeysImmediate(["C-u"]);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/login");
      await session.waitForText("Connections", TIMEOUT);
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  180_000,
);
