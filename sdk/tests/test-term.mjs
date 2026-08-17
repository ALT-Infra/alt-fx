#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxTerminal, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-term.mjs");
  process.exit(2);
}

const output = [];
const streamedDecoder = new TextDecoder();
let streamedText = "";
const originalSetTimeout = globalThis.setTimeout;
let observeZeroTimeouts = false;
let zeroTimeoutCount = 0;
globalThis.setTimeout = (callback, delay = 0, ...args) => {
  if (observeZeroTimeouts && Number(delay) === 0) zeroTimeoutCount += 1;
  return originalSetTimeout(callback, delay, ...args);
};
const dataListeners = new Set();
const resizeListeners = new Set();
let drainCalls = 0;
let drainCompleted = false;
const terminal = {
  cols: 80,
  rows: 24,
  write(bytes) {
    const chunk = bytes instanceof Uint8Array ? bytes : new TextEncoder().encode(bytes);
    output.push(chunk);
    streamedText += streamedDecoder.decode(chunk, { stream: true });
    process.stdout.write(chunk);
  },
  async drain() {
    drainCalls += 1;
    await new Promise((resolve) => setTimeout(resolve, 10));
    drainCompleted = true;
  },
  onData(callback) {
    dataListeners.add(callback);
    return () => dataListeners.delete(callback);
  },
  onResize(callback) {
    resizeListeners.add(callback);
    return () => resizeListeners.delete(callback);
  },
};

const persistedConfig = new Map([
  ["model", "sdk/term-model"],
  ["mode", "plan"],
]);
const events = [];
const encoded = new TextEncoder();
let requestedModel;
let streamStartedAt;
let streamFinishedAt;
const mockFetch = async (_url, init) => {
  requestedModel = new Headers(init.headers).get("ai-language-model-id");
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"hello"}\n'));
      streamStartedAt = performance.now();
      let emitted = 0;
      const interval = setInterval(() => {
        emitted += 1;
        if (emitted < 30) {
          controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"."}\n'));
          return;
        }
        clearInterval(interval);
        streamFinishedAt = performance.now();
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":" world"}\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n"));
        controller.close();
      }, 20);
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal,
  env: { AI_GATEWAY_API_KEY: "term-test-key" },
  fetch: mockFetch,
  configStore: {
    get(configId) { return persistedConfig.get(configId) ?? null; },
    set(configId, value) { persistedConfig.set(configId, value); },
  },
  onEvent(event) { events.push(event); },
  traceWasi: process.env.FX_WASI_TRACE === "1",
  stderr(bytes) { process.stderr.write(bytes); },
});
await Promise.race([
  runtime.interactive,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for fx-term to become interactive")), 5000)),
]);
const startupDeadline = performance.now() + 5000;
while (!streamedText.includes("Run /help for commands")) {
  if (performance.now() >= startupDeadline) throw new Error("timed out waiting for startup output");
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (drainCalls !== 1 || !drainCompleted) throw new Error("interactive resolved before the terminal adapter drained");
runtime.write("hello");
runtime.write("\x1b[D");
runtime.write("!");
runtime.write("\x7f");
runtime.write("\r");
const deadline = performance.now() + 5000;
while (streamStartedAt === undefined) {
  if (performance.now() >= deadline) throw new Error("timed out waiting for continuous fx-term response");
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const liveDraft = "queued draft";
observeZeroTimeouts = true;
runtime.write(liveDraft);
while (!streamedText.includes(liveDraft)) {
  if (streamFinishedAt !== undefined) throw new Error("terminal did not render follow-up input while the response was active");
  if (performance.now() >= deadline) throw new Error("timed out waiting for live follow-up input");
  await new Promise((resolve) => setTimeout(resolve, 10));
}
observeZeroTimeouts = false;
while (streamFinishedAt === undefined) {
  if (performance.now() >= deadline) throw new Error("timed out waiting for streamed fx-term response");
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await new Promise((resolve) => setTimeout(resolve, 100));
runtime.write("\x7f".repeat(liveDraft.length));
runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for fx-term exit")), 5000)),
]);
globalThis.setTimeout = originalSetTimeout;
const text = new TextDecoder().decode(Buffer.concat(output.map((chunk) => Buffer.from(chunk))));

if (exitCode !== 0) throw new Error(`fx-term exited with code ${exitCode}`);
if (!text.includes("𝒇x")) throw new Error("shared Fx welcome frame was not observed");
if (!text.includes("Run /help for commands")) throw new Error("shared Fx welcome guidance was not observed");
if (requestedModel !== "sdk/term-model") throw new Error(`terminal prompt did not use the host-restored model: ${requestedModel}`);
if (!(streamStartedAt < streamFinishedAt)) throw new Error("terminal fetch did not remain active for continuous streaming");
if (zeroTimeoutCount !== 0) throw new Error(`terminal allocated ${zeroTimeoutCount} zero-timeout poll timer(s)`);
if (!events.some((event) => event.type === "config.restore" && event.configId === "model")) throw new Error("terminal model restore event was not emitted");
if (!events.some((event) => event.type === "config.restore" && event.configId === "mode")) throw new Error("terminal mode restore event was not emitted");
console.error(`term SDK smoke passed: exit=${exitCode}, bytes=${Buffer.byteLength(text)}`);
