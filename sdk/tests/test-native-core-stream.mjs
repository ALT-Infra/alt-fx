#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const server = createServer((request, response) => {
  if (request.method !== "POST") {
    response.writeHead(404).end();
    return;
  }
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    const payload = JSON.parse(body);
    assert.ok(payload);
    assert.ok(payload.tools == null || payload.tools.length === 0, "N-API core must not advertise native tools");
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.write('data: {"type":"text-delta","delta":"native"}\n\n');
    response.write('data: {"type":"text-delta","delta":" stream"}\n\n');
    response.write('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n');
    response.end("data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
try {
  let fetchCalls = 0;
  const agent = await createFxAgent({
    nativeAddon: addon,
    backend: "native",
    fetch(input, init) {
      fetchCalls += 1;
      return fetch(input, init);
    },
    env: {
      AI_GATEWAY_API_KEY: "native-core-stream-key",
      FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${port}/chat`,
      FX_MODEL: "native/test-model",
    },
  });
  const session = await agent.createSession();
  const turn = session.prompt("hello from native");
  let text = "";
  for await (const update of turn) {
    if (update.sessionUpdate === "agent_message_chunk" && !update.content.text.startsWith("[context]")) {
      text += update.content.text;
    }
  }
  assert.equal(text.trimEnd(), "native stream");
  assert.equal(fetchCalls, 1, "N-API Gateway transport must use the Node-owned fetch option");
  assert.equal((await turn.result).stopReason, "end_turn");
  await session.close();
  assert.equal(await agent.close(), 0);
  console.log("native core stream passed: POST, SSE deltas, async iteration, and graceful close");
} finally {
  server.close();
}
