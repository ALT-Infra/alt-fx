import { expect } from "bun:test";

const permissionModeContext = {
  ask: "Runtime context: permission mode is ask. Sensitive tool calls may require user approval unless configured rules or session grants already decide them. Tool admission remains authoritative.",
  auto: "Runtime context: permission mode is auto. After configured rules, session grants, and deterministic direct-command authority, Fx reviews each unresolved sensitive tool call once. The reviewer either allows that exact action or sends it to the user for approval. Tool admission remains authoritative.",
  yolo: "Runtime context: permission mode is yolo. Fx permission policy and sandboxing are disabled. Tool lookup, argument validation, execution authority, cancellation, limits, operating-system permissions, and remote authentication remain authoritative.",
} as const;

export function expectPermissionModeContext(
  body: string,
  mode: keyof typeof permissionModeContext,
) {
  const request = JSON.parse(body) as {
    prompt: Array<{ role?: string; content?: unknown }>;
  };
  const messages = request.prompt.map((message) => ({
    role: message.role,
    text: typeof message.content === "string" ? message.content : "",
  }));
  const expected = permissionModeContext[mode];
  const matching = messages.filter((message) => message.text === expected);

  expect(matching).toHaveLength(1);
  for (const [candidateMode, context] of Object.entries(permissionModeContext)) {
    if (candidateMode === mode) continue;
    expect(messages.some((message) => message.text === context)).toBe(false);
  }
  expect(matching[0]!.role).toBe("system");
  const modeIndex = messages.findIndex((message) => message.text === expected);
  expect(
    messages[modeIndex + 1]?.text.startsWith(
      "Runtime context: shell commands run ",
    ),
  ).toBe(true);
}
