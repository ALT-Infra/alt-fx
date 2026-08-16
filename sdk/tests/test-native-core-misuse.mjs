#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addonPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const addon = require(addonPath);

for (const [name, args] of [
  ["createCore", []],
  ["writeCore", []],
  ["writeCore", [{}]],
  ["closeCore", []],
  ["drainCore", []],
  ["coreExited", []],
  ["coreExitCode", []],
  ["destroyCore", []],
]) {
  assert.throws(() => addon[name](...args), {
    name: "TypeError",
    code: "LIBFX_INVALID_ARGUMENT",
    message: "missing required argument",
  });
}

const getterError = new Error("host getter failed");
assert.throws(
  () => addon.createCore(Object.defineProperty({}, "apiKey", { get() { throw getterError; } })),
  (error) => error === getterError,
);
assert.throws(
  () => addon.createCore(new Proxy({}, { has() { throw getterError; } })),
  (error) => error === getterError,
);

for (const [options, message] of [
  [{ apiKey: "x".repeat(64 * 1024 + 1), home: "/tmp", workspaceRoot: "/tmp" }, /apiKey/],
  [{ apiKey: "key", model: "x".repeat(1025), home: "/tmp", workspaceRoot: "/tmp" }, /model/],
  [{ apiKey: "key", home: "x".repeat(16 * 1024 + 1), workspaceRoot: "/tmp" }, /home/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "http://attacker.example/chat" }, /gatewayChatUrl/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "https://user:pass@example.com/chat" }, /gatewayChatUrl/],
  [{ apiKey: "key", home: "/tmp", workspaceRoot: "/tmp", gatewayChatUrl: "https://example.com/chat" }, /gatewayChatUrl/],
]) {
  assert.throws(() => addon.createCore(options), message);
}

for (const fakeHandle of [null, undefined, {}, Buffer.alloc(0), 0, "handle"]) {
  assert.throws(
    () => addon.coreExited(fakeHandle),
    (error) => error instanceof TypeError || error.code === "LIBFX_INVALID_ARGUMENT" || error.code === "LIBFX_NAPI",
  );
}

const core = addon.createCore({ apiKey: "misuse-test-key", home: "/tmp", workspaceRoot: "/tmp" });
assert.throws(
  () => addon.writeCore(core, Buffer.alloc(8 * 1024 * 1024 + 1)),
  (error) => error.code === "LIBFX_NATIVE_BACKPRESSURE",
);
addon.writeCore(core, Buffer.alloc(0));
addon.closeCore(core);
addon.destroyCore(core);
assert.throws(
  () => addon.coreExited(core),
  (error) => error.code === "LIBFX_NATIVE_CLOSED",
);

console.log("native core misuse passed: argument, size, backpressure, and closed-handle checks are enforced");
