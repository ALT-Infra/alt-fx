# fx

## 0.0.2

<!-- release:start -->

### New Features

- **Unified terminal execution:** Run captured foreground commands and durable interactive sessions through the `terminal` tool, with the user's shell profile loaded by default and `clean` as an explicit opt-out
- **Saved session permissions:** Store exact allow or deny rules with `/permissions remember`, list them by stable ID, and remove them with `/permissions revoke`
- **MCP server awareness:** Show the agent the configured server aliases, availability, and visible tool counts so it can find and use MCP capabilities

### Improvements

- **Auto mode recovery:** Let the agent revise its plan after denied, timed-out, or invalid reviews and return a tools-disabled response after repeated blocks instead of stalling for approval
- **Trusted auto mode actions:** Allow bounded reads, hardened read-only Git commands, and prepared workspace edits to proceed without extra review while keeping ambiguous or sensitive actions gated
- **MCP connection reliability:** Connect to legacy stdio servers, cancel stalled reloads, and report the required `oauth.issuer` override when issuers do not match
- **MCP failure handling:** Show concise server errors and stop a third matching failed call before it runs
- **Terminal action recovery:** Reject invalid terminal fields before running anything and return one complete correction without repeating the same repair loop
- **Fast mode defaults:** Start new sessions with `zai/glm-5.2` without enabling Fast mode while preserving explicit preferences and `/fast`

### Bug Fixes

- **WebAssembly terminal input:** Keep input responsive during continuous streams, queue follow-up prompts until the active response completes, and preserve the queued prompt text
- **Terminal job cleanup:** Force-close descendant jobs spawned by any Linux thread and return `session_lost` when fx cannot confirm complete cleanup

<!-- release:end -->

## 0.0.1

### New Features

- **Current fx documentation:** Route questions about fx through the public documentation index before answering

### Improvements

- **Scoped project instructions:** Continue safe read-only inspections after loading more specific project instructions and defer only affected state-changing tools
- **Light terminal readability:** Improve syntax highlighting and help contrast on light terminal backgrounds while keeping redirected and structured output uncolored
- **Transcript review navigation:** Preserve tail following, scroll bookmarks, and expanded command history when switching between Ctrl+O Review and Full detail
- **Binary size safeguards:** Track native binary growth across every supported platform
- **Release validation reliability:** Harden asynchronous terminal and Gateway readiness checks to prevent false failures

### Bug Fixes

- **Wrapped diff layout:** Keep wrapped file-diff rows aligned with their gutters across Inline, Review, and Full detail
- **Inline picker layout:** Keep the transcript and composer adjacent when closing inline pickers instead of leaving a blank band in the frame
- **Native Node.js fetch lifecycle:** Keep native sessions reusable after early response completion, cancel only the matching host fetch, and reject incompatible addon versions before startup
- **Terminal cleanup:** Allow tmux sessions a bounded settling period after shutdown while retaining strict ownership checks
