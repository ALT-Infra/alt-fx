# fx WebAssembly SDK

The experimental fx WebAssembly SDK embeds fx in a JavaScript host. `fx-core.wasm` runs a headless Agent Client Protocol (ACP) agent, and `fx-term.wasm` runs the interactive terminal.

## Try the SDK locally

Build both WebAssembly surfaces and start a local server from the repository root:

```sh
zig build -Dwasm-surface=core
zig build -Dwasm-surface=term
python3 -m http.server 8080
```

After the local server starts, open one of the included demos:

- [Open the core debugger on localhost](http://localhost:8080/sdk/index.html)
- [Open the interactive terminal on localhost](http://localhost:8080/sdk/term-demo.html)

The demos require [JavaScript Promise Integration (JSPI)](https://v8.dev/blog/jspi), which `supportsJspi()` detects. Use Chrome or Edge 137 or later.

## JavaScript API

[`fx-sdk.js`](fx-sdk.js) is a dependency-free ECMAScript module that exports:

- `createFxAgent()` for the headless ACP surface
- `createFxTerminal()` for the terminal surface
- `supportsJspi()` for capability detection
- `encodeXtermKeyEvent()` for terminal key translation
- `xtermAdapter()` for xterm.js integration

JavaScript hosts can provide configuration, prompt history, session persistence, device login, URL opening, and a foreground workspace. The optional workspace adapter exposes only `run_command`, with command execution delegated to the host.

WebAssembly builds do not include native processes, OS sandboxing, native Model Context Protocol (MCP), subagents, skills, auto-upgrade, clipboard integration, arbitrary WASI filesystem access, or web search.

See [AGENTS.md](AGENTS.md) for implementation constraints and validation commands.
