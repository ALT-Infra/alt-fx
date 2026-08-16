#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const events = [];
const agent = await createFxAgent({
  nativeAddon: addon,
  backend: "native",
  env: { AI_GATEWAY_API_KEY: "native-core-test-key" },
  onEvent(event) { events.push(event); },
});
const session = await agent.createSession();
assert.equal(typeof session.id, "string");
assert.ok(session.id.length > 0);
assert.ok(Array.isArray(session.configOptions));
assert.ok(session.modes);
const sessions = await agent.listSessions();
assert.ok(Array.isArray(sessions));
await session.close();
assert.equal(await agent.close(), 0);
assert.ok(events.some((event) => event.type === "runtime.ready"));
assert.ok(events.some((event) => event.type === "acp.receive"));
console.log("native core passed: initialize, session/new, session/list, and graceful close");
