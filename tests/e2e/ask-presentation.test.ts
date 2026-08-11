import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewaySerializedToolCall,
  fakeGatewayToolCall,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const TERMINAL_FIXTURE_SHELL = terminalFixtureShell();
const MARKDOWN =
  "# Ask presentation\n\n" +
  "**bold** and [docs](https://example.com)\n\n" +
  "- first item\n- second item\n\n---\n\n" +
  "| Name | Value |\n| --- | --- |\n| one | two |\n\n" +
  "```zig\nconst answer: u8 = 42;\n```\n";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  await Promise.all(roots.map(waitForTerminalHostExit));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

async function waitForTerminalHostExit(root: string): Promise<void> {
  const identityPath = join(root, "home", ".fx", "terminal-host", "host.json");
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }
  throw new Error(`terminal host did not exit for ${root}`);
}

function createRoot() {
  const root = mkdtempSync(join(tmpdir(), "fx-e2e-ask-presentation-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  roots.push(root);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function createShortRoot() {
  const root = realpathSync(mkdtempSync("/tmp/fx-ask-terminal-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  roots.push(root);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function gatewayEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
): Record<string, string | undefined> {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-ask-presentation-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/v1/models`,
  };
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function terminalCommand(args: string[]): string {
  const fx = [FX_BIN, ...args].map(shellQuote).join(" ");
  const script = `${fx}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
  return `/bin/sh -c ${shellQuote(script)}`;
}

describe("fx ask presentation", () => {
  test.skipIf(!tmuxAvailable())(
    "fx ask executes the shared public terminal tool through the tmux backend",
    async () => {
      const root = createShortRoot();
      const toolCallId = "ask_terminal_tmux_1";
      const gateway = startFakeGateway(
        [
          fakeGatewayToolCall(toolCallId, "terminal", {
            action: "start",
            cwd: root.workspace,
            command: "printf ASK_PUBLIC_TERMINAL_TMUX",
            shell: {
              kind: "executable",
              path: TERMINAL_FIXTURE_SHELL,
              clean_start: true,
            },
            backend: "tmux",
            return_when: { kind: "exit" },
            wait_ceiling_ms: 8_000,
            dimensions: { rows: 24, columns: 80 },
          }),
          fakeGatewayFinalText("Ask public terminal complete.\n"),
        ],
        { classifierResponses: [fakeGatewayPermissionDecision()] },
      );
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--auto", "Run the tmux public terminal fixture."],
        {
          cwd: root.workspace,
          env: {
            ...gatewayEnv(root.home, gateway),
            FX_TERMINAL_HOST_IDLE_MS: "200",
          },
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toBe("Ask public terminal complete.\n");
      expect(result.stderr).toContain("Using terminal start");
      expect(result.stderr).not.toContain("failed");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain(toolCallId);
      expect(gateway.requests[1]!.body).toContain('\\"backend\\":\\"tmux\\"');
      expect(gateway.requests[1]!.body).toContain('\\"exited\\":0');
    },
    TIMEOUT,
  );

  test("redirected and JSON stdout preserve raw assistant Markdown", async () => {
    const root = createRoot();
    const rawGateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
    gateways.push(rawGateway);
    const raw = await runFx(["ask", "--no-save", "Render the fixture."], {
      cwd: root.workspace,
      env: gatewayEnv(root.home, rawGateway),
      timeoutMs: TIMEOUT,
    });

    expect(raw.code).toBe(0);
    expect(raw.stdout).toBe(MARKDOWN);
    expect(raw.stdout).not.toContain("\x1b");
    expect(raw.stderr).toBe("");

    const jsonGateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
    gateways.push(jsonGateway);
    const json = await runFx(
      ["ask", "--json", "--no-save", "Render the fixture."],
      {
        cwd: root.workspace,
        env: gatewayEnv(root.home, jsonGateway),
        timeoutMs: TIMEOUT,
      },
    );

    expect(json.code).toBe(0);
    expect(JSON.parse(json.stdout).output).toBe(MARKDOWN);
    expect(json.stdout).not.toContain("\x1b");
    expect(json.stderr).toBe("");
  }, TIMEOUT);

  test.skipIf(!tmuxAvailable())(
    "TTY stdout uses the Minimal transcript and compact tool group",
    async () => {
      const root = createRoot();
      writeFileSync(join(root.workspace, "fixture.txt"), "fixture contents\n");
      let releaseFinal: (() => void) | undefined;
      const finalReady = new Promise<void>((resolve) => {
        releaseFinal = resolve;
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("read_fixture", "read_file", { path: "fixture.txt" }),
        fakeGatewaySerializedToolCall(
          "read_missing",
          "read_file",
          JSON.stringify({ path: "missing.txt" }),
          "Between groups.\n",
        ),
        async () => {
          await finalReady;
          return fakeGatewayFinalText(MARKDOWN);
        },
      ]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        cmd: terminalCommand([
          "ask",
          "--auto",
          "--no-save",
          "Inspect fixture.txt and render the response.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("Between groups.", TIMEOUT);
      await session.resizeWindow(104, 36);
      releaseFinal!();
      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const pane = await session.capturePane();
      const scrollback = await session.captureFullScrollback();
      const escaped = await session.captureFullScrollbackEscapes();
      expect(scrollback).toContain("Inspect fixture.txt and render the response.");
      expect(pane.match(/1 tool call · 1 read/g)).toHaveLength(2);
      expect(pane).toContain("Reading fixture.txt");
      expect(pane).toContain("Between groups.");
      expect(pane).toContain("Reading missing.txt");
      expect(pane).toContain("failed");
      expect(pane).toContain("Ask presentation");
      expect(pane).toContain("bold and docs");
      expect(pane).toContain("first item");
      expect(pane).toContain("const answer: u8 = 42;");
      expect(pane).not.toContain("# Ask presentation");
      expect(pane).not.toContain("**bold**");
      expect(escaped).toContain("\x1b[");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "--no-color keeps the TTY layout without Fx styles or hyperlinks",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([fakeGatewayFinalText(MARKDOWN)]);
      gateways.push(gateway);

      const session = await TmuxSession.create({
        cmd: terminalCommand([
          "ask",
          "--no-color",
          "--no-save",
          "Render the no-color fixture.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const pane = await session.captureFullScrollback();
      const escaped = await session.captureFullScrollbackEscapes();
      expect(pane).toContain("Render the no-color fixture.");
      expect(pane).toContain("Ask presentation");
      expect(pane).toContain("bold and docs");
      expect(pane).toContain("const answer: u8 = 42;");
      expect(escaped).not.toMatch(/\x1b\[[0-9;]*m/);
      expect(escaped).not.toContain("\x1b]8;");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "TTY Minimal hides context and auto-approval notices",
    async () => {
      const root = createRoot();
      const instructions = join(root.root, "instructions.md");
      writeFileSync(instructions, "# Fixture instructions\n");
      symlinkSync(instructions, join(root.workspace, "AGENTS.md"));
      const gateway = startFakeGateway(
        [
          fakeGatewayToolCall("write_fixture", "run_command", {
            command: "printf notice-test > ask-notice.txt",
          }),
          fakeGatewayFinalText("Notice filtering complete.\n"),
        ],
        { classifierResponses: [fakeGatewayPermissionDecision()] },
      );
      gateways.push(gateway);

      const session = await TmuxSession.create({
        cmd: terminalCommand([
          "ask",
          "--auto",
          "--no-save",
          "Run the notice filtering fixture.",
        ]),
        cwd: root.workspace,
        env: { ...gatewayEnv(root.home, gateway), NO_COLOR: undefined },
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      sessions.push(session);

      await session.waitForText("__FX_EXIT_0__", TIMEOUT);
      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("Run the notice filtering fixture.");
      expect(scrollback).toContain("Notice filtering complete.");
      expect(scrollback).toContain("1 tool call · 1 command");
      expect(scrollback).not.toContain("project instructions");
      expect(scrollback).not.toContain("Auto agent approved this request");
      expect(scrollback).not.toContain("● System:");
    },
    TIMEOUT,
  );
});
