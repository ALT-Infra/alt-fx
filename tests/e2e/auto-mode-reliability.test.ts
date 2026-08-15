import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayPermissionDecision,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let activeSession: TmuxSession | null = null;

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-auto-mode-reliability-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission: {}, maxxing_mode: "legacy" }),
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-auto-mode-reliability-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "auto",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function commandCall(command: string, id: string) {
  return fakeGatewayToolCall(id, "run_command", { command });
}

function startGateway(
  responses: Parameters<typeof startFakeGateway>[0],
  classifierResponses: NonNullable<
    Parameters<typeof startFakeGateway>[1]
  >["classifierResponses"] = [],
) {
  const gateway = startFakeGateway(responses, { classifierResponses });
  gateways.push(gateway);
  return gateway;
}

async function waitForEither(
  session: TmuxSession,
  expected: string[],
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let scrollback = "";
  while (Date.now() < deadline) {
    scrollback = await session.captureFullScrollback();
    if (expected.some((value) => scrollback.includes(value))) return scrollback;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${expected.map(JSON.stringify).join(" or ")}`);
}

describe("lean auto mode reliability", () => {
  test(
    "a deterministically safe action bypasses automatic review",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startGateway(
        [commandCall("pwd", "direct_pwd"), fakeGatewayFinalText("direct action complete")],
        [fakeGatewayPermissionDecision("ask", "unused_review")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Print the working directory."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr.toLowerCase()).not.toContain("permission required");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      const json = JSON.parse(result.stdout.trim()) as {
        tool_calls: Array<{ name: string; status: string }>;
      };
      expect(json.tool_calls).toContainEqual(
        expect.objectContaining({ name: "run_command", status: "success" }),
      );
    },
    TIMEOUT,
  );

  test(
    "a first automatic block returns to the agent for a safe replan",
    async () => {
      const root = createIsolatedRoot();
      const rejectedMarker = join(root.workspace, "rejected-action-must-not-run");
      const gateway = startGateway(
        [
          commandCall(`touch ${JSON.stringify(rejectedMarker)}`, "rejected_action"),
          (body) => {
            expect(body).toContain("auto_denied");
            expect(body).toContain("rejected_action");
            return commandCall("pwd", "safe_replan");
          },
          (body) => {
            expect(body).toContain("safe_replan");
            return fakeGatewayFinalText("safe replan complete");
          },
        ],
        [fakeGatewayPermissionDecision("ask", "reject_first_action")],
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Complete the task safely."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stderr.toLowerCase()).not.toContain("permission required");
      expect(existsSync(rejectedMarker)).toBe(false);
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.classifierRequests).toHaveLength(1);
      const json = JSON.parse(result.stdout.trim()) as { output: string };
      expect(json.output).toContain("safe replan complete");
    },
    TIMEOUT,
  );

  test(
    "three blocked responses escalate the next unresolved action without a fourth review",
    async () => {
      const root = createIsolatedRoot();
      const markers = Array.from(
        { length: 4 },
        (_, index) => join(root.workspace, `blocked-action-${index + 1}-must-not-run`),
      );
      const gateway = startGateway(
        markers.map((marker, index) => (body?: string) => {
          if (index > 0) expect(body).toContain("auto_denied");
          return commandCall(`touch ${JSON.stringify(marker)}`, `blocked_action_${index + 1}`);
        }),
        Array.from(
          { length: 3 },
          (_, index) => fakeGatewayPermissionDecision("ask", `blocked_review_${index + 1}`),
        ),
      );

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Try the task without unsafe actions."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(1);
      expect(result.stdout).toContain("NonInteractivePermissionRequired");
      expect(gateway.requests).toHaveLength(4);
      expect(gateway.classifierRequests).toHaveLength(3);
      for (const marker of markers) expect(existsSync(marker)).toBe(false);
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "a prompt-capable host also lets the agent recover before asking the user",
    async () => {
      const root = createIsolatedRoot();
      const rejectedMarker = join(root.workspace, "tui-rejected-action-must-not-run");
      const stderrPath = join(root.root, "stderr.log");
      writeFileSync(stderrPath, "");
      const gateway = startGateway(
        [
          commandCall(`touch ${JSON.stringify(rejectedMarker)}`, "tui_rejected_action"),
          (body) => {
            expect(body).toContain("auto_denied");
            return commandCall("pwd", "tui_safe_replan");
          },
          fakeGatewayFinalText("TUI safe replan complete"),
        ],
        [fakeGatewayPermissionDecision("ask", "tui_reject_first_action")],
      );

      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 120,
        height: 40,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Complete the task safely.");
      const scrollback = await waitForEither(
        activeSession,
        ["TUI safe replan complete", COMMAND_APPROVAL_PROMPT],
        TIMEOUT,
      );

      expect(scrollback).toContain("TUI safe replan complete");
      expect(scrollback).not.toContain(COMMAND_APPROVAL_PROMPT);
      expect(existsSync(rejectedMarker)).toBe(false);
      expect(gateway.requests).toHaveLength(3);
      expect(gateway.classifierRequests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;
    },
    TIMEOUT,
  );
});
