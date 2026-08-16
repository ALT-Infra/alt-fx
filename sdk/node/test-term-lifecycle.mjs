#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

function instrumentTerminal(terminal, disposals, onWrite = () => {}) {
  const host = xtermAdapter(terminal);
  return {
    write(bytes) { onWrite(bytes); host.write(bytes); },
    onData(callback) {
      const unsubscribe = host.onData(callback);
      return () => { disposals.data += 1; unsubscribe(); };
    },
    onResize(callback) {
      const unsubscribe = host.onResize(callback);
      return () => { disposals.resize += 1; unsubscribe(); };
    },
    get cols() { return host.cols; },
    get rows() { return host.rows; },
  };
}

function terminalGrid(terminal) {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}

const terminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
let terminalWriteCount = 0;
let terminalOutput = "";
const outputDecoder = new TextDecoder();
const disposals = { data: 0, resize: 0 };
const instrumentedTerminalHost = instrumentTerminal(terminal, disposals, (bytes) => {
  terminalWriteCount += 1;
  terminalOutput += outputDecoder.decode(bytes, { stream: true });
});
const events = [];
let fetchStarted = false;
let fetchAborted = false;
const fetch = async (_url, init) => {
  fetchStarted = true;
  return new Promise((_, reject) => {
    init.signal.addEventListener("abort", () => {
      fetchAborted = true;
      reject(new DOMException("aborted", "AbortError"));
    }, { once: true });
  });
};
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: instrumentedTerminalHost,
  env: { AI_GATEWAY_API_KEY: "term-lifecycle-key" },
  fetch,
  onEvent(event) { events.push(event); },
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => terminalGrid(terminal);
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${grid()}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

await waitFor(() => grid().includes("𝒇x"), "startup");
terminal.resize(112, 36);
await waitFor(
  () => events.some((event) => event.type === "terminal.resize" && event.cols === 112 && event.rows === 36) &&
    events.some((event) => event.type === "terminal.size" && event.cols === 112 && event.rows === 36),
  "resize propagation",
);

const themeQueryStart = terminalOutput.length;
runtime.write("\x1b[?997;2n");
await waitFor(
  () => terminalOutput.slice(themeQueryStart).includes("\x1b[c"),
  "theme response-fence query",
);
runtime.write("\x1b[?1;2c");
await waitFor(
  () => terminalOutput.slice(themeQueryStart).includes("\x1b]11;?\x1b\\\x1b[c"),
  "fenced OSC 11 query",
);
const themeRepaintStart = terminalOutput.length;
runtime.write("\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?1;2c");
await waitFor(() => {
  const repaint = terminalOutput.slice(themeRepaintStart);
  return repaint.includes("\x1b[3J") && repaint.includes("\x1b[38;5;247m");
}, "light theme retint and repaint");

const submittedAt = performance.now();
runtime.write("wait forever\r");
await waitFor(() => fetchStarted, "stalled fetch");
await waitFor(
  () => grid().includes("Thinking") && grid().includes("wait forever"),
  "accepted prompt presentation before network response",
);
const acceptanceLatencyMs = performance.now() - submittedAt;
if (acceptanceLatencyMs >= 1000) {
  throw new Error(`accepted prompt presentation took ${acceptanceLatencyMs.toFixed(1)}ms`);
}
const writesAfterAcceptance = terminalWriteCount;
await waitFor(
  () => terminalWriteCount >= writesAfterAcceptance + 2,
  "animated terminal frames while fetch is stalled",
);
await waitFor(() => grid().includes("Thinking (1s)"), "thinking counter while fetch is stalled");
runtime.write("\x03");
await waitFor(() => fetchAborted, "fetch abort");
await waitFor(() => grid().includes("Cancelled") || grid().includes("cancelled"), "cancelled turn presentation");

runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for exit")), 5000)),
]);
if (exitCode !== 0) throw new Error(`fx-term exited with ${exitCode}`);
await new Promise((resolve) => setTimeout(resolve, 0));
const exitEvents = events.filter((event) => event.type === "runtime.exit");
if (exitEvents.length !== 1) throw new Error(`expected one runtime.exit event, got ${exitEvents.length}`);
if (disposals.data !== 1 || disposals.resize !== 1) {
  throw new Error(`terminal subscriptions were not released exactly once: data=${disposals.data}, resize=${disposals.resize}`);
}

const abortTerminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
const abortDisposals = { data: 0, resize: 0 };
const abortRuntime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: instrumentTerminal(abortTerminal, abortDisposals),
  env: { AI_GATEWAY_API_KEY: "term-lifecycle-key" },
  fetch,
});
const abortFlush = () => new Promise((resolve) => abortTerminal.write("", resolve));
const abortGrid = () => terminalGrid(abortTerminal);
const abortStartupDeadline = performance.now() + 5000;
while (!abortGrid().includes("𝒇x")) {
  await abortFlush();
  if (performance.now() >= abortStartupDeadline) throw new Error(`timed out waiting for abort runtime startup:\n${abortGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
abortRuntime.abort();
if (await abortRuntime.exited !== 130) throw new Error("aborted terminal did not exit with code 130");
if (abortDisposals.data !== 1 || abortDisposals.resize !== 1) {
  throw new Error(`aborted terminal subscriptions were not released exactly once: data=${abortDisposals.data}, resize=${abortDisposals.resize}`);
}
console.log("headless lifecycle passed: theme retinted, resize propagated, and Ctrl-C cancelled stalled fetch");
