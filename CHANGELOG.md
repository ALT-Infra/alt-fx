# fx

## 0.4.5

<!-- release:start -->

### Bug Fixes

- **Stable upgrades:** Keep manual and background upgrades on the same forward-only release order across version-line transitions
<!-- release:end -->

## 0.4.4

### New Features

- **Native Node.js agents:** Run headless fx agents inside Node.js through a native `libfx` addon, with fetch streaming and cancellation handled by the host
- **Shared JavaScript SDK:** Use `createFxAgent()` and `createFxTerminal()` from `libfx` in Node.js or the browser, with WebAssembly fallback when a native surface is unavailable

### Bug Fixes

- **Signed-in account data:** Restore model catalog and credit balance loading for Vercel-authenticated sessions

## 0.4.3

### Improvements

- **Smaller macOS arm64 binary:** Reduce the native binary size with profile-guided optimization tuned to common fx workloads

## 0.4.2

### New Features

- **MCP configuration diagnostics:** `fx status`, `fx status --json`, and `fx doctor` report invalid `~/.fx/mcp.json` profiles without starting MCP servers

### Improvements

- **Default model:** New sessions use `zai/glm-5.2` with Fast mode enabled when neither preference is configured and preserve any explicit choice
- **Update and resume notices:** Show the installed version after a Ctrl+G update relaunch and include the session title when restoring a saved session
- **Terminal ask output:** Terminal `fx ask` sessions show the shared fx startup header before the prompt, while redirected and JSON output remain unchanged
- **Recovery diagnostics:** Retry and paused recovery statuses show available HTTP, provider, or transport error details after redacting secrets and terminal control bytes
- **Child approvals:** Parent agents receive child approval requests during the same turn while the child remains blocked for a decision

### Bug Fixes

- **Transcript scrollback:** Keep mutable streaming rows out of native scrollback until they are final, while continuing to update the live viewport and preserving aligned cancellation frames after resize
- **Recovery continuation:** Accept one `/continue` as soon as a recovery pause appears, even while the previous worker finishes cleanup
- **Recovery pacing:** Keep one recovery attempt budget across failure causes and reset backoff after the cause changes, an explicit retry delay, authentication refresh, or a successful request
- **Terminal tool compatibility:** Keep the `terminal` tool available when providers apply stricter schema validation while continuing to reject fields unsupported by the selected action

## 0.4.1

### New Features

- **Private diagnostic traces:** `/trace` creates a private Markdown diagnostic; on macOS, fx copies the file to the clipboard, while other platforms save it and print its path

### Improvements

- **Feedback flow:** `/feedback` opens the feedback form without creating a trace or changing the clipboard
- **Inline settings menus:** `/appearance`, `/statusline`, and `/sandbox` use compact inline controls, preview status-line changes live, and apply updates without extra transcript messages
- **Slash command history:** Accepted slash commands persist with prompt history, recall their resolved form, and remain available after restart
- **Network recovery:** Native agent turns automatically retry transient network failures, including immediate connection resets and macOS wake errors, through one bounded recovery flow
- **Terminal tool calls:** fx accepts structured terminal arguments encoded as JSON strings and rejects fields that do not belong to the selected action before changing the session

### Bug Fixes

- **Terminal monitor paths:** Show `Failed start: path is outside the workspace` when a start monitor resolves beyond its terminal workspace
- **Terminal titles:** Restore `fx · <model>` on startup, keep it current after resume and model selection, and clear it after startup failures or shutdown
- **Resumed subagents:** Prevent Ctrl+X manager refreshes from restarting incomplete recovery while allowing later explicit subagent operations to retry it

## 0.4.0

### New Features

- **WebAssembly terminal sessions:** The experimental terminal SDK can now sign in and restore persisted sessions across reloads
- **Hosted workspace commands:** The WebAssembly terminal can run commands supplied by its host workspace

### Improvements

- **WebAssembly terminal output:** Stream assistant Markdown and tables more smoothly in the terminal SDK
- **Feedback reports:** `/feedback` now copies a diagnostic report and opens a prefilled GitHub issue form, with guidance to review and redact sensitive information before submitting
- **Agents and processes:** The Ctrl+X manager now groups agents and background processes with clearer labels, actions, counts, and compact layouts
- **Background terminals:** Background sessions remain available through Ctrl+X while the normal footer stays quieter, and terminal takeover now shows how to detach

### Bug Fixes

- **Interactive terminal startup:** Start an interactive shell when the `terminal` tool receives an empty command
- **Ctrl+X manager layout:** Keep the close action visible on narrow terminals and align status labels correctly for wide Unicode names

## 0.3.73

### New Features

- **Persistent terminal sessions:** Add a durable `terminal` tool with native PTY and tmux backends, output and state monitors, direct `!` commands, Command Center status, and full-screen interactive takeover (#1276)
- **WebAssembly SDK:** Add embeddable headless-agent and terminal builds with `createFxAgent()`, `createFxTerminal()`, host-provided transport and storage, streaming, cancellation, session restore, settings, and prompt history (#1340)
- **Local Vision paths:** Attach approved files selected with `@`, pasted into prompts, or passed through `/image` and `--image`, with call-scoped snapshots that protect against path replacement and special-file races (#1402)
- **Private feedback:** Add a `/feedback` flow that discloses and copies the diagnostic report before privately submitting it, while retaining the local report when delivery fails (#1417)
- **Credential onboarding:** Show Vercel sign-in and API-key choices on the first launch without credentials, with session-only dismissal and compact-terminal support (#1413)
- **Live terminal demo:** Build the terminal WebAssembly artifact during marketing deploys and route demo requests through a rate-limited same-origin Gateway proxy without exposing the site credential (#1403, #1404)

### Improvements

- **MCP permission context:** Show bounded MCP argument previews in root and subagent approval prompts without changing the arguments that execute (#1420)
- **Typed terminal input:** Decode raw terminal bytes into Core-owned actions, including approval choices and amendments, while preserving key, paste, mouse, cancellation, and redraw behavior (#1389, #1406)
- **Gateway-driven Fast mode:** Derive Fast support from live Gateway metadata, send the supported speed option explicitly, and reject redundant toggles on intrinsically fast model aliases (#1412, #1414)
- **Simpler menus:** Present `/help` as a linear command catalog and compact `/settings` into aligned rows with inline model and value controls (#1410, #1411)
- **MCP schema compatibility:** Keep tools available when their schemas contain unsupported but valid assertions, while continuing to reject malformed schemas, unsafe references, and invalid inputs that fx understands (#1421)
- **Smaller release binary:** Reduce duplicated ReleaseSafe code and oversized constants through shared MCP sorting, fieldwise initialization, and compact message assembly (#1401)
- **Current documentation:** Consolidate public guides, navigation, CLI help, SDK instructions, and MCP references around the current product surface and lowercase fx branding (#1395, #1409, #1419)
- **Upgrade reload shortcut:** Move installed-update reloads from `Ctrl+R` to `Ctrl+G` while preserving `Ctrl+U` editing behavior (#1400)
- **Gateway identification:** Send `user-agent: fx/<version>` with every Gateway request (#1397)
- **Multiline approvals:** Render physical command newlines as separate approval rows while escaping other control characters (#1399)

### Bug Fixes

- **Paste suffix isolation:** Reject bracketed paste when ambiguous bytes trail the closing marker in the same delivery, preserving the draft and keeping those bytes out of terminal responses (#1416)
- **Transcript scrollback:** Preserve terminal history when transcript replay releases rows while excluding transient activity and footer content (#1415)
- **Greeting color:** Keep the static landing greeting aligned with the light-theme handoff color (#1405)

### Contributors

- @fazxes
- @suarezesteban
- @rauchg
- @shaper

## 0.3.72

### New Features

- **Complete MCP client:** Support MCP `2026-07-28` over stdio and Streamable HTTP, preserve compatibility with legacy stdio, Streamable HTTP, and HTTP+SSE servers, and expose session-scoped MCP capabilities across the interactive shell, `fx ask`, ACP, and permission-filtered subagents (#1356)
- **MCP feature surface:** Add tools, resources, resource templates, prompts, completion, pagination, cache-aware discovery, subscriptions, progress, cancellation, and form or URL elicitation with bounded protocol handling (#1356)
- **MCP authentication and policy:** Validate tool schemas and arguments, support bearer credentials and OAuth with secure storage and refresh, distinguish required and optional servers, and add health reporting, transactional reload, resume, isolation, and bounded teardown (#1356)
- **Gateway-driven model controls:** Populate reasoning choices from live model metadata, keep Fast mode independent from the model ID, and accept new Gateway values without requiring an Fx release (#1388)
- **Transcript view navigation:** Use `Ctrl+O` to open and close transcript review, switch between Review and Full detail with Left and Right, and keep composer focus and the status line stable (#1393)
- **Mobile docs search:** Search titles, sections, headings, descriptions, and full page content from the mobile Browse panel with ranked local results and contextual snippets (#1391)
- **Agent-readable documentation:** Add sticky mobile navigation, one-click Markdown copying, Markdown versions of every docs page, content negotiation with `Accept: text/markdown`, and `/llms.txt` and `/llms-full.txt` indexes (#1385)

### Improvements

- **Core composer transitions:** Centralize selection, kill and yank history, trailing-backslash line continuation, skill binding, and whole-draft replacement across root, child, and manager composers while preserving undo boundaries and structured input metadata (#1369, #1371, #1376, #1378, #1383)
- **Current product documentation:** Add guides and references for project instructions, additional workspaces, automation, Vision, context limits, ACP, MCP, configuration, sessions, permissions, and tools while correcting stale terminology and references (#1372, #1373)
- **Lightweight landing terminal:** Replace the landing-page Linux VM boot with a static preview that tracks the published Fx version while retaining the separate `/linux/run` environment (#1368)
- **Simpler site logo:** Replace the WebGPU metal-logo pipeline and `/metal` inspector with a lightweight SVG shimmer, soften the effect, and limit it to hover.
- **Regression test stability:** Align ACP authentication fixtures with team-aware model discovery, verify paced questions through terminal replay, and wait for persistent subagents to become idle before paging history (#1365)

### Bug Fixes

- **Credential persistence:** Remember successful `/login` choices and API keys saved through `/setup`, including the active team, across shell restarts (#1387)
- **Structured Vision responses:** Enforce the Vision success and failure schema through the Gateway response contract instead of prompt-only JSON formatting (#1394)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit
## 0.3.71

### New Features

- **Filesystem path picker:** Browse current, parent, home, and absolute paths from `@` completion, include empty directories, keep the picker open while traversing folders, quote paths with spaces, and insert selected files without attaching their contents (#1355)
- **Metal logo experience:** Add a GPU-rendered metal logo, a dedicated `/metal` page, a responsive site header, and a landing-page scroll hint (#1361)

### Improvements

- **Responsive long-session transcripts:** Interrupt transcript construction for pending input, rebuild only changed tails, reuse width-independent relationships, and restore resumed history in bounded batches so `Ctrl+O` and Escape remain responsive (#1324)
- **Large approval reviews:** Open file approvals before full diff projection finishes, keep navigation and resizing responsive, and preserve access to the complete transcript and diff (#1349)
- **Core composer deletion:** Route character, word, and selection deletion through one Core contract across root composers, child chats, and manager forms while keeping image and skill entities atomic (#1359)
- **Live tool payload progress:** Keep the activity marker, elapsed time, and output-token estimate moving while tool arguments stream before the tool publishes its own status (#1360)
- **Darwin process spawning:** Use `posix_spawnp` for macOS child processes while preserving environment, working directory, stdio, process-group, wait, and kill behavior (#1350)
- **Vision evidence handling:** Accept complete evidence within the total response budget, preserve valid sibling results, and return actionable diagnostics for local, provider, outage, and output-limit failures (#1363)
- **Faster Full CI:** Run four duration-balanced E2E shards per platform and optimization mode, reuse pinned tool and build caches, start native and E2E lanes independently, and tighten synchronization across terminal tests (#1341)

### Bug Fixes

- **Interrupted resume writes:** Restore the exact transcript endpoint after incomplete append attempts so resumed history is not lost (#1346)
- **Streaming scrollback rows:** Preserve every streamed transcript row when terminal newline translation is disabled (#1354)
- **Resume composer stability:** Paint exact same-layout snapshots with current startup notices and wait for authoritative replay when geometry or retained history differs, preventing composer jumps (#1348)
- **Session reset header:** Restore the launch header after `/clear`, `/new`, and `/reset` without retaining prior transcript output (#1352)
- **Marketing styles:** Bust the stale immutable CSS artifact that left the metal logo and scroll hint unstyled after deployment.

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit

## 0.3.70

### New Features

- **Composer shortcuts:** Add character, word, line, paragraph, visual-row, and page movement; Shift selection; select all, copy, cut, undo, and redo; and `Ctrl+L` redraw for root and child composers (#1270)
- **Credential-aware model discovery:** Load public models before sign-in, discover private team models across supported Vercel credentials, recover from expired authentication, and show catalog access and fallback state in the CLI and TUI (#1328)
- **Resume picker flag:** Open the session picker with `fx -r`, preserve the existing last-session aliases, and create a writable session when the startup picker closes without a selection (#1344)

### Improvements

- **Faster session resume:** Paint bounded, styled transcript snapshots before authoritative replay, preserve native scrollback and composer placement, and safely fall back when cached state is missing or invalid (#1322)
- **Installed upgrade handoff:** Install verified automatic upgrades before prompting, start new sessions from the installed build, and make `Ctrl+R` reload that executable while resuming the current session (#1336)
- **Queued prompt presentation:** Collapse queued prompts to a count until review opens, then render them as spaced composer drafts that match the active input appearance (#1331, #1342)
- **Quieter streaming status:** Show the live token counter without a redundant Streaming label or blinking marker while assistant text prints (#1343)
- **Core composer transitions:** Route root and child insertion, range replacement, undo, and redo through Core-owned contracts while preserving entity spans, paste limits, selection, and allocation-failure atomicity (#1327, #1332, #1347)
- **Dual-mode CI:** Run native builds, unit tests, and deterministic E2E coverage in both Debug and ReleaseSafe across all four supported platforms (#1335)

### Bug Fixes

- **Composer stability:** Keep compact tool completion from shifting the tool status, thinking row, or composer when transcript content and terminal geometry are unchanged (#1339)
- **Live terminal themes:** Keep adaptive tint synchronized with terminal background changes, ignore stale replies, retry unanswered probes, and preserve Escape input during checks (#1334, #1337)
- **ReleaseSafe permission coverage:** Prevent optimized structured-grant tests from crashing and stabilize permission prompt and file-picker E2E timing (#1338)
- **Marketing navigation:** Highlight the most specific active link on nested documentation routes (#1333)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit

## 0.3.69

### New Features

- **5.6 model controls:** Add extra-high and maximum reasoning choices plus Fast mode for the 5.6 Sol, Terra, and Luna models, and ignore stale unsupported reasoning settings without disabling Fast mode (#1311)

### Improvements

- **Resume menu performance:** Preload current-workspace and all-workspace pages, keep cached rows visible during refreshes, parse only the requested page, and defer full history loading until a session is selected (#1300)
- **Core worker presentation:** Move tool activity, worker status, selected-child activity, and lifecycle transitions into Core while preserving status priority, event ordering, cancellation, cleanup, and session persistence (#1313, #1316, #1320, #1323)
- **Assistant output ordering:** Keep text, tables, code blocks, and thematic rules in their original order for root and selected-child conversations, including partial output during interruption (#1321)
- **Simpler footer:** Remove the subagent count and Ctrl+X hint from the normal footer while keeping Ctrl+X manager access and the active manager exit hint (#1315)
- **Contributor guidance:** Remove references to architecture, roadmap, and status documents that do not exist in the repository (#1312)

### Bug Fixes

- **Resumed interruption state:** Show cancellation and failure markers when interrupted sessions resume, hide completed-tool interruption summaries from replay, and preserve the context needed for follow-up requests (#1319)
- **Auto-upgrade recovery:** Isolate stable and dev staging files across concurrent sessions and keep the current process running when a staged upgrade disappears instead of relaunching the same binary (#1314)
- **Inline modal placement:** Keep pickers and prompts attached to newly appended transcript content, leave unused rows below the composer, and preserve displaced scrollback without duplicate transcript rows (#1318)
- **Ctrl-O cursor:** Restore the composer cursor immediately after the transcript view closes (#1325)
- **Terminal theme ordering:** Ignore late background-color replies from older probes so the newest terminal theme remains active (#1326)

### Contributors

- @fazxes

## 0.3.68

### Breaking Changes

- **Browser tools removed:** Remove the built-in browser automation tools and their CDP configuration while preserving system URL opening for login and historical browser tool calls in saved sessions (#1299)

### New Features

- **Dev release channel:** Let users opt into stable or dev builds with `fx upgrade --channel`, persist the selected channel across automatic upgrades and Ctrl+R handoffs, show channel and revision details in `fx status`, and publish tested main commits to the public CDN (#1294)
- **Additional workspaces by default:** Enable `--add-dir` and saved workspace directories without the experimental environment flag, and simplify workspace status output (#1307)

### Improvements

- **Copyable resume handoff:** Print the exact `fx --resume <id>` command in the active theme, keep it on one line when space permits, and use the same syntax in help, recovery output, and documentation (#1304)
- **Question prompt ownership:** Render live question prompts from Core-owned state while preserving option details, freeform drafts, batch progress, submission, and cancellation (#1302)

### Bug Fixes

- **Streaming scrollback:** Keep wheel and page scrolling in native terminal scrollback while output streams, retain Ctrl+O as the explicit transcript viewer, and preserve navigation after the viewer opens (#1306)

### Contributors

- @fazxes

## 0.3.67

### Breaking Changes

- **Summary command removed:** Remove `/summary` from the interactive command list and ACP discovery while leaving `/compact` and automatic context compaction unchanged (#1292)
- **Plan mode removed:** Limit ACP sessions to code and ask modes and remove the undocumented `fx ask --plan` flag while preserving the read-only tool policy (#1293)

### New Features

- **Live release status:** Show the current CDN release version and experimental status below the marketing install command, with a cached lookup and keyboard-accessible details (#1267)

### Improvements

- **Workspace path completion:** Search tracked and untracked nonignored files and directories across workspace roots, rank fuzzy matches, highlight matching segments, retain results during refresh, and insert directory completions with a trailing slash (#1272)
- **Transcript review performance:** Keep `Ctrl-O` responsive in long sessions with indexed projections and bounded viewport rendering, preserve the selected position through output and resize, and tighten file diff presentation (#1280)
- **Core interaction ownership:** Move horizontal composer navigation, usage-menu state, input reset, approval amendments and decisions, approval prompts, and question prompts into Core while keeping terminal decoding and presentation in UI (#1265, #1275, #1277, #1284, #1290, #1295, #1298)
- **Smaller release binary:** Consolidate repeated sorting, tracing, width measurement, cleanup, and rendering code; move a metrics buffer to BSS; report binary size per CI target; and compress notification chimes without changing playback (#1273, #1285)
- **Marketing site:** Use the Fx mark for icons and social cards, restore the landing and overview copy, upgrade to Next.js 16.3, enable partial prefetching, and correct mobile overflow and alignment (#1268, #1269, #1283, #1286, #1287, #1289)
- **E2E reliability:** Stabilize request-counting checks for externally owned children and wait for image turns to persist before validating session metadata (#1271)

### Bug Fixes

- **Native scrollback:** Preserve compact notices and rows displaced by growing inline footers, keep selected transcript rows fixed during streaming, and limit mouse capture to states that consume it (#1263, #1279, #1296)
- **Subagent cancellation:** Publish configured cancellation notifications before manager cancellation returns, suppress disabled notifications, and preserve exactly one delivery across retries and restarts (#1266)
- **Subagent boundaries:** Prevent model-created children from exceeding parent authority, keep child file mutations out of root undo history, and preserve reviewed configuration drafts across concurrent changes (#1278, #1281)
- **Status-line persistence:** Keep the session status-line preference across launches while preserving its default-off behavior and legacy migration (#1288)
- **Upgrade handoff:** Resume open sessions after another process promotes a staged upgrade and avoid writing a literal `fx (deleted)` file during concurrent Linux promotion (#1291)
- **Permission review:** Keep automatic permission review running when Vision projection removes historical messages, fall back to manual review on ambiguous alignment, and prevent the projection panic (#1297)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit
- @TY37zhang

## 0.3.66

### New Features

- **Progressive transcript detail:** Open a bounded Review view with the first `Ctrl-O` press and exhaustive Full detail with the second, while preserving transcript order, active item, draft, and running work across view changes, resize, approvals, and child chats (#1236)

### Improvements

- **Core interaction ownership:** Move bracketed paste framing, gesture timing, registered input entities, composer history, kill ring state, workspace menu state, decoded input actions, vertical navigation, and input-limit rejection state into Core while preserving existing editing and interaction behavior (#1241, #1245, #1246, #1251, #1253, #1256, #1258, #1261, #1262)
- **Marketing navigation and logo:** Enable instant client navigation across the site, keep touch scrolling and keyboard activation intact, and refine the themed logo shimmer and mark balance (#1244, #1248, #1250)
- **Documentation:** Align the docs with current CLI and runtime behavior, add guides for authentication, usage, appearance, tools, and recordings, and restore table rendering (#1255)

### Bug Fixes

- **Queued subagent permissions:** Preserve the originating root request with queued child work across restarts so auto mode classifies the first sensitive child action with its full permission context (#1242)
- **Subagent state integrity:** Preserve corrupt relationship-index evidence, show degraded manager state, reject new messages when the communication ledger is corrupt, and keep concurrent sends available during atomic control-record replacement (#1252, #1254)
- **Child lifecycle ownership:** Reject direct resume of one-off child sessions across CLI, interactive, and ACP paths, and show externally owned children as busy without allowing the wrong process to cancel them (#1257, #1260)
- **Terminal-safe child names:** Render control characters in selected child names as inert visible text while preserving printable Unicode and raw persisted identity (#1247)
- **Approval transitions:** Deny `open_file` when automatic review asks for human approval without launching it, and close file or child approval screens in one synchronized terminal transition (#1249)

### Contributors

- @fazxes
- @rauchg
- @suarezesteban

## 0.3.65

### New Features

- **Interrupted response recovery:** Persist partial responses, tool progress, retry budgets, and recovery checkpoints across interactive, CLI, ACP, and subagent sessions, with continuation after network loss, provider cooldowns, process restarts, and Mac sleep (#1230)
- **Approved relationship changes:** Apply reviewed subagent attach and reparent operations after one-time approval, keep concurrent approval surfaces single-winner, and retain the reviewed relationship across retryable failures (#1229)

### Improvements

- **Core input ownership:** Move input appearance, editor state, pasted blocks, picker transitions, and UTF-8 scalar admission into Core while preserving editing, selection, paste, completion, staged model selection, and drop diagnostics (#1225, #1227, #1231, #1238, #1240)
- **Gateway provider boundaries:** Route credits and agent streaming through registered providers across interactive, CLI, ACP, subagent, and Vision requests while preserving credentials, request ordering, retries, cancellation, tool calls, and usage reporting (#1223, #1232)
- **Skills navigation:** Keep arrow-key navigation responsive with large skill catalogs and correct the slash-menu command count (#1228)
- **Native CI coverage:** Run complete Zig and deterministic E2E checks on native Linux and macOS runners for x86_64 and ARM64, with isolated shards and more reliable timing-sensitive assertions (#1219, #1221)
- **Documentation and site:** Add the skills reference page and refresh the landing page and docs around Fx's open-source, model-agnostic agent-harness positioning (#1234, #1235)

### Bug Fixes

- **Composer caret stability:** Restore the visible caret after synchronized terminal frames and keep it at the insertion point during native terminal clear checks (#1222, #1226)
- **Relationship picker context:** Keep the selected target, distinguishing suffix, full action, and load-more control visible in short or narrow attach pickers (#1233)
- **Child file approvals:** Show the requesting child, target path, and bounded change preview; reuse an approved workspace scope for later child writes while requiring separate approval outside it (#1239)

### Contributors

- @fazxes
- @rauchg
- @bennor

## 0.3.64

### New Features

- **Model-aware prompt limits:** Size retained history and generation output from the selected model, raise the main composer safety boundary to 8 MiB, and return distinct CLI and ACP overflow errors (#1216)
- **Cross-workspace sessions:** Add `fx sessions --all` so sessions remain discoverable after a workspace moves or is renamed (#1210)
- **Option word navigation:** Support Herdr-translated Option+Left and Option+Right sequences for composer word movement (#1207)

### Improvements

- **Command summaries:** Show workspace paths relative to the current directory and use singular or plural command counts in compact tool groups (#1211)
- **Runtime ownership:** Route web search contracts, managed skill-root policy, question answers, background processes, and built-in or MCP tool execution through explicit Core providers and registries (#1205, #1206, #1212, #1215, #1218)
- **E2E reliability:** Isolate terminal tests from inherited runtime state, use local Gateway fixtures, and wait for durable terminal and session state in timing-sensitive scenarios (#1204)

### Bug Fixes

- **CLI and subagent reliability:** Return correct automation exit statuses, reject invalid prompt bytes, speed up background child lookup, and fix child catalog, projection, and resume-state updates (#1214)
- **Session and protocol integrity:** Preserve child drafts, queued prompts, and session visibility while hardening CLI and ACP argument parsing, initialization, and prompt ordering (#1210)
- **Child approvals:** Preserve requesting-child ownership, action details, permission choices, and fast Escape-arrow message routing (#1201)
- **Diagnostics and help:** Treat a missing home directory as absent settings, report the Fx version through ACP, and explain resume conflicts with `--no-save` (#1217)

### Contributors

- @fazxes
- @scotttrinh

## 0.3.63

### Bug Fixes

- **Native terminal scrollback:** Restore mouse-wheel scrollback in new and resumed sessions by limiting mouse reporting to alternate-screen views and removing composer pointer selection (#1202)

### Contributors

- @fazxes

## 0.3.62

### New Features

- **Session recovery:** Add `fx session recover <id>` to create a separately resumable session from a canonical event log, preserve verified images, and keep failed Ctrl+R or upgrade handoffs from losing the active session (#1190)
- **Pointer editing:** Add click-to-place, drag selection, replacement editing, and cut support to the composer while preserving terminal-native selection behavior (#1186)

### Improvements

- **Session and skill menus:** Render skills as aligned single-line rows, add resume-menu contrast, automatic paging, and clamped navigation, and preserve active selections and source labels in narrow layouts (#1179, #1180, #1182, #1194)
- **Sign-in flow:** Open the browser as soon as a device code is ready while preserving Enter-based reopening and the headless opt-out (#1183)
- **Thinking duration:** Format long thinking times with readable hour, minute, and second units instead of raw seconds (#1184)
- **Registered tool execution:** Route subagent, Vision, and web-search execution through registered callbacks while preserving permissions, capabilities, cancellation, failures, and usage reporting (#1187, #1189, #1191, #1195)

### Bug Fixes

- **Subagent stability:** Fix child catalog dismissal, skill binding, paste feedback, concurrent scrollback, cancellation, nested messaging, file creation, failed reads, relationship repair, and resume ownership edge cases (#1181, #1188, #1196)
- **Decision prompt context:** Keep prior transcript context visible when questions and approvals open, reserve prompt spacing through the shared frame layout, and preserve hidden-composer yank ownership (#1193, #1197)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.61

### New Features

- **Subagent manager:** Add persistent and one-off subagent sessions with durable messaging, per-child models and permissions, transcript inspection, lifecycle controls, and a dedicated Ctrl-X manager (#1125)
- **Local usage reporting:** Add authoritative local usage and cost reporting through `fx usage`, `/usage`, and `/cost`, with session and rolling time windows plus text and JSON output (#1118)

### Improvements

- **Session continuity:** Print an exact resume command after eligible exits and redesign `/resume` as compact single-line rows with aligned metadata and adaptive paging (#1139, #1162)
- **Runtime and host contracts:** Route clipboard, OAuth, login URL opening, credentials, generation usage, notifications, shell commands, and browser admission through bounded Core and host providers (#1136, #1142, #1146, #1154, #1156, #1160, #1164, #1167)
- **MCP startup:** Start interactive sessions without waiting for MCP discovery while preserving tool availability, status, reload, and shutdown behavior (#1152)
- **Decision editing:** Add standard cursor and deletion shortcuts to approvals and freeform questions, and keep long approval amendments scrolled to the active cursor and feedback (#1143, #1173)
- **Terminal presentation:** Refine review diff colors, tool status weight, slash-menu selection, and compact catalog layouts (#1144, #1145, #1155, #1166)
- **Documentation and coverage:** Rewrite the README as a practical Fx manual, correct the MCP configuration path, and make ACP external-write permission coverage deterministic (#1128, #1147, #1175)

### Bug Fixes

- **Composer navigation:** Keep Home, End, Ctrl+A, and Ctrl+E on the current logical line, preserve shortcuts immediately after Escape, and honor disabled prompt history (#1170, #1171, #1172)
- **Completion behavior:** Stabilize slash completion across whitespace, wrapping, arguments, and no-match states; fix `@file` token boundaries and Enter routing; and preserve skill source identity, ranking, selection, and spacing (#1149, #1153, #1158, #1159)
- **Footer geometry:** Preserve transcript and composer placement after footer surfaces close, questions are cancelled, or constrained terminals resize (#1161, #1165)
- **Unicode rendering:** Keep wide and multi-codepoint glyphs intact at terminal boundaries and restore no-wrap mode after interrupted writes (#1168)
- **Stream retries:** Retry `ReadFailed` streams only while replay is safe, preventing duplicate output and tool effects while preserving partial context (#1157)
- **Process and terminal cleanup:** Reap detached background processes safely and keep tmux window switching usable throughout startup, resume, and shutdown (#1141, #1150)
- **Automatic file review:** Keep edits with long diff lines eligible for automatic approval within the existing review budget (#1148)

### Contributors

- @fazxes
- @suarezesteban
- @bennor

## 0.3.60

### New Features

- **Inline slash completion:** Add composer completion for slash commands without leaving the input surface (#1120)
- **Next-turn model selection:** Allow model changes during an active response and apply them to the following turn (#1138)
- **fx.sh installer:** Serve installation through `fx.sh` and update product install commands to use the new endpoint (#1121, #1123)

### Improvements

- **Runtime ownership:** Route CLI, ACP, subagent UI, notifications, execution, Gateway access, and web-fetch content through owned registries and Core contracts (#1117, #1126, #1129, #1132)
- **Thinking timer:** Exclude approval and question wait time from the active Thinking counter (#1124)
- **Decision controls:** Keep decision-prompt shortcuts isolated and dismiss focused input before response cancellation (#1130, #1134)

### Bug Fixes

- **ACP session state:** Report busy ACP sessions accurately instead of accepting conflicting work (#1122)
- **Composer stability:** Prevent the caret from jumping when a prompt is submitted (#1135)
- **Queued images:** Preserve queued image snapshots through kill-and-yank operations (#1127)
- **Narrow fenced text:** Preserve fenced content layout at constrained terminal widths (#1131)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.59


### Improvements

- **Provider boundaries:** Route app, CLI, MCP, skills, slash commands, model catalogs, and default prompt policy through explicit providers and registries (#1110, #1112, #1113, #1114, #1116)
- **Terminal polish:** Add model-picker, model-switch, question-answer, diff-marker, header, skill-completion, and session-title refinements (#1072, #1077, #1078, #1079, #1084, #1096, #1115)
- **Session performance:** Speed up session commits and reduce resume overhead (#1094)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit
- @tz
## 0.3.58


### Breaking Changes

- **Stored API key source:** The `auth` value in `fx status --json` and `fx doctor --json` changed on macOS from `macOS Keychain` to `stored API key (macOS Keychain)`. The Keychain-only credential source is now one platform-neutral stored-key source with two backends, and the label names whichever backend answered. Machine-readable consumers matching the old string need updating.
- **Vercel CLI provisioning removed:** `/setup` no longer shells out to the Vercel CLI to create an AI Gateway key on your behalf. Paste an existing key instead, or run `/login` to sign in with Vercel. Installing or authenticating the Vercel CLI is no longer part of any fx auth path.

### New Features

- **Stored API key on every platform:** A stored AI Gateway API key now persists in the macOS Keychain on macOS and in a `0600` file under `~/.fx/` elsewhere. The file is written atomically and refused on read if its permissions grant group or other access, which stays distinguishable from no key being stored.

### Improvements

- **The credential you pick is remembered:** Choosing a source under `/setup` now persists to `~/.fx/settings.json` and is preferred on every later run, including over `AI_GATEWAY_API_KEY` and `VERCEL_OIDC_TOKEN`. A remembered source that no longer resolves falls back to the usual precedence rather than failing, an **Automatic** row returns to precedence on demand, and signing out clears a remembered login so it cannot reactivate later.
- **Saving an API key no longer freezes the shell:** the gateway check and the key-store write run on a worker, so a locked keychain or a slow network leaves the interface responsive instead of blocking it for up to ten seconds.
- **A short model list explains itself:** `fx models` notes when team-private models are withheld because the active credential is an fx login, and `--json` reports it as `private_models_hidden`. An API key lists them and stays silent.
- **Expired logins are reported, not hidden:** `fx status` and `fx doctor` emit `auth_expired` and mark the doctor auth check as a warning when an fx login session is past its refresh deadline, rather than reporting a healthy credential. Both commands remain read-only and never refresh the session.
- **`/setup` is one screen stack:** `/setup` now opens a four-action footer hub for Vercel sign-in, API key entry, team changes, and credential switching. Sign-in stays inside the live terminal, API key input is masked, and secrets never reach the transcript, shell history, or trace log.

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit

## 0.3.57

### New Features

- **Vision tool:** Add image understanding for text-only models with bounded image handling and resilient retries (#1008)

### Improvements

- **Composer semantics:** Preserve drafts, prompt history, queued prompts, image snapshots, and kill-and-yank entities through editing and navigation (#1035, #1039, #1044, #1051, #1056)
- **Tool ownership:** Move web search, web fetch, skill installation, and task specs into their built-in owners and centralize mode tool policy (#1043, #1049, #1052, #1053, #1055)
- **Session resume:** Make large-session resume linear-time and keep the picker responsive through contention and errors (#1038, #1050)
- **Terminal polish:** Adopt a monochrome palette, blinking thinking markers, clearer narrow picker options, and faster landing-page terminal startup (#1045, #1046, #1047, #1048)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit
## 0.3.56

### New Features

- **YOLO permissions:** Add unrestricted YOLO permission mode for trusted workflows (#1032)
- **Composer and command menus:** Add a compact command menu and category visibility setting, with inline cost and workspace controls (#1022, #1033)
- **Dynamic MCP lifecycle:** Show lifecycle states for dynamically registered MCP tools (#1021)

### Improvements

- **Composer editing:** Keep draft entities, image pastes, kill-and-yank operations, and general edits atomic, bounded, and Unicode-safe (#1028, #1031, #1034, #1035, #1039)
- **Tool routing:** Keep provider-advertised tools paired with executable runtime handlers and report unsupported tool failures in minimal mode (#1029, #1036)
- **Terminal presentation:** Hide command output in minimal mode and move informational notices and completed-tool markers to the neutral tone (#1024, #1026, #1030)
- **Marketing site:** Refresh the landing page with a terminal-inspired design, refined typography, and improved terminal polish (#1025, #1040)

### Contributors

- @fazxes
- @suarezesteban
- @evilrabbit
## 0.3.55

### New Features

- **Appearance controls:** Add a unified `/appearance` picker for terminal presentation choices (#1013)
- **Compact controls:** Add compact status-line and sandbox menus, with settings-catalog alignment refinements (#1007, #1016)
- **Question prompts:** Redesign interactive questions with compact controls and hardened text handling (#1010, #1014)

### Improvements

- **Permission review:** Refine interactive approval prompts and review larger file mutations in auto mode (#1011, #1015)
- **Streamed tool activity:** Reconcile streamed tool-call identities and keep grouped tool output stable across handoffs and model steps (#1012, #1018, #1019)
- **Picker behavior:** Keep the transcript stable after picker dismissal and preserve the closed picker state (#1009)

### Bug Fixes

- **File edits:** Show actionable reasons when file mutations cannot proceed (#1017)

### Contributors

- @fazxes
## 0.3.54

### New Features

- **Interactive catalogs:** Add searchable full-screen catalogs for `/help`, `/models`, `/resume`, `/settings`, and `/skills` with keyboard navigation and scoped edit shortcuts (#988, #997, #1002, #1003, #1005)
- **Live usage:** Show streaming token totals in the terminal while a response is in progress (#999)
- **Sound levels:** Add a maximum sound level with dedicated release and toggle cues for `/sound` (#1000)

### Improvements

- **CLI and ask presentation:** Expand command help and render `fx ask` with the compact presentation while keeping internal notices out of its output (#982, #992)
- **Session and composer continuity:** Speed up large-session resume, preserve queued-prompt scrollback, and harden composer ownership and cleanup across interactive transitions (#995, #998, #1004)
- **Permissions and tool admission:** Move Gateway permission review into built-ins, inject the active reviewer consistently, and route external paths through normal tool admission (#985, #989, #991)
- **Terminal navigation:** Improve slash-command menu layout and behavior, clarify approval Tab behavior, and collapse verbose startup diagnostics (#990, #993, #1001)
- **Runtime integration:** Move Herdr lifecycle hooks into built-ins and strengthen transcript, rendering, and command lifecycle coverage (#983)

### Bug Fixes

- **Review cancellation:** Preserve cancellation behavior for `fx ask` permission review instead of continuing after cancellation (#994)
- **Clipboard feedback:** Verify `/feedback` clipboard copies and clarify the `/paste` clipboard description (#979, #980)

### Contributors

- @fazxes
- @suarezesteban
## 0.3.53

### New Features

- **Sound cues:** Add `/sound` controls and `FX_SOUND` override with native macOS cues and terminal-bell fallback for launch, completion, failure, cancellation, and model-state changes (#986)

### Improvements

- **Tool-set ownership:** Separate active tool-set ownership from model advertisement so runtime dispatch and prompt construction share one authoritative registry (#967)
- **Terminal visual styling:** Refine thinking indicators, accent colors, notices, inline-code rendering, and truecolor fallbacks for a more coherent terminal surface (#969)
- **Minimal tool groups:** Dim grouped tool headers and rows while retaining full-contrast assistant and detail views (#986)

### Contributors

- @fazxes
- @suarezesteban
## 0.3.52

### New Features

- **WebAssembly tool execution:** Route WebAssembly tool targets through the host boundary with the same runtime contract as native tools (#973)

### Improvements

- **Minimal presentation:** Make the compact presentation the default and group tool activity into concise per-step summaries (#963, #965)
- **Gateway recovery:** Reset connection state between setup epochs so stalled Gateway streams can recover cleanly (#971)
- **Unicode rendering:** Render display sequences atomically and anchor terminal table dividers correctly across terminal widths (#972)
- **MCP tool registry:** Reserve MCP tool names through the active registry and expose the resolved names consistently across runtimes (#974)
- **Startup and provider configuration:** Reduce session startup work and compose the devbox provider during application initialization (#961, #968)

### Bug Fixes

- **Interrupt controls:** Clear stale Ctrl+C exit hints and keep bare Escape from accidentally exiting the shell (#970)
- **Skill installation:** Serialize concurrent installs to prevent conflicting updates to managed skills (#964)
- **Tool output settings:** Remove the ineffective configurable tool-output setting and use the supported presentation behavior (#975)
- **Prompt guidance:** Align conditional guidance with the tools actively advertised to the model (#959)

### Contributors

- @fazxes
## 0.3.51

### New Features

- **CLI tool sets:** Inject the active tool set into `fx ask` for schema advertisement and runtime dispatch (#945)
- **Minimal activity summaries:** Group tool activity by model step with canonical actions, targets, and compact completion states (#946)
- **Cancelled tool feedback:** Show cancelled tools, cancellation details, and follow-up prompts directly in the transcript (#952)
- **Session publication recovery:** Resume interrupted session publications from their last valid committed state across TUI, ask, and ACP (#957)

### Improvements

- **Provider-portable history:** Preserve system-role prefixes and replay interruption, background, file-evidence, and summary context across providers (#947)
- **Skill discovery and installation:** Centralize built-in roots, route installs through the tool registry, and harden metadata and command compatibility checks (#948, #955, #958)
- **Permission and tool registration:** Expose captured permission mode in model context and move web-search advertisement into the tool registry (#949, #950)
- **Decision guidance:** Choose terminal-width-aware prompt and approval hints that keep Enter and Escape actions visible (#951)
- **Usage reconciliation:** Start resumed usage reconciliation only after application initialization reaches the final app address (#954)
- **Runtime lifecycle:** Preserve late command output, improve session cleanup, and strengthen durable auth, permission, and resume coverage (#953)
- **Composer interaction:** Preserve spaces and Enter around dollar-prefixed skill mentions while keeping deliberate skill bindings intact (#956)

### Bug Fixes

- **Runtime recovery:** Preserve late command output through worker completion and terminal recovery, and clean up failed API-key sessions safely (#953)
- **Skill installs:** Reject overlapping command matches, preserve existing installs on replacement failure, and keep incomplete transactions out of discovery (#958)
- **Skill mentions:** Prevent spaces from being consumed and allow Enter to submit when a dollar mention has no selectable result (#956)
- **Session resume:** Recover malformed pending publications before ranking resumable sessions and preserve durable state on indeterminate failures (#957)
- **History replay:** Omit provider-invalid history shapes while retaining chronological interruption and background context (#947)

### Contributors

- @fazxes

## 0.3.50

### New Features

- **Workspace directories:** Add experimental saved and process-only workspace roots with CLI and slash-command controls (#922)
- **Portable reasoning effort:** Expose model reasoning controls across TUI, `fx ask`, ACP, subagents, and image retries (#934)
- **Minimal presentation mode:** Make the compact presentation the default and retain the original UI as `/maxxing legacy` (#940)
- **Explicit interruption controls:** Treat submitted text as normal agent input and leave interruption to explicit controls (#942)

### Improvements

- **Skill metadata and loading:** Support multiline descriptions, strict metadata validation, lazy bounded reads, and safer installation diagnostics (#933, #938)
- **Context and permissions:** Share workspace access scope across runtime surfaces and preserve exact request context during automatic review (#918, #922)
- **Session accounting:** Persist and reconcile cumulative model usage and cost across resume and delegated generations (#936)
- **ACP lifecycle:** Consolidate ACP session activation, task persistence, background restoration, and workspace capability handoff (#931)
- **Workflow and tool execution:** Consolidate streamed tool-input transitions and GitHub CLI workflow execution while preserving existing contracts (#921, #928)
- **Transcript notices:** Render interactive notices through one semantic formatting contract across transcript, background, approval, and subagent views (#932, #939)

### Bug Fixes

- **Session history:** Omit empty assistant messages when rebuilding resumed prompts while preserving completed tool calls after provider failures (#930)
- **Command grants:** Match approved command-bearing session grants exactly without changing configured wildcard rules (#941)
- **Composer resize:** Reposition the composer immediately after terminal resize and retain reflow state through the settled frame (#937)
- **Full transcript resize:** Keep scrolled Ctrl-O transcripts visible when the terminal shrinks (#943)
- **Skill safety:** Isolate malformed or unsafe skill candidates and propagate cancellation and resource failures instead of returning partial success (#933)
- **Context notices:** Preserve exact notice control bytes and avoid duplicate painter and frame-surface handling (#932)

### Contributors

- @fazxes

## 0.3.49

### New Features

- **Skill metadata:** Support block descriptions in `SKILL.md` frontmatter and preserve skill names without loading instruction bodies (#920)
- **Bounded context:** Add configurable limits for skills, MCP, project instructions, images, and model context before Gateway requests (#896)

### Improvements

- **Permission review:** Preserve the exact model request and pending tool-call batch as context for automatic permission review (#918)
- **Skill loading:** Require explicit skill reads, keep resources bounded and resumable, and improve diagnostics for invalid candidates (#896, #919, #920)
- **Workflow execution:** Consolidate GitHub CLI workflow execution for `fx pr` and `fx issue` while preserving command-specific behavior (#921)
- **Command preferences:** Route `/input`, `/output`, `/statusline`, and `/notifications` persistence through a shared helper (#923)
- **Transcript rendering:** Keep context and successful auto-approval notices out of the compact transcript while retaining them in Ctrl-O detail views (#925, #926)

### Bug Fixes

- **Permission context:** Ask for interactive confirmation when automatic review cannot safely complete instead of losing the original request context (#918)
- **Context limits:** Prevent oversized skill, MCP, project-instruction, image, and model-context payloads from exceeding configured or emergency limits (#896)
- **Compact transcript:** Prevent context and auto-approval notices from cluttering the normal interactive transcript while preserving their full-detail records (#925, #926)
- **Skill discovery:** Isolate malformed skill candidates and report invalid roots without loading unintended instruction content (#919, #920)

### Contributors

- @fazxes

## 0.3.48

### New Features

- **Multiline question answers:** Support bracketed paste and wrapped multiline input in freeform question prompts (#909)
- **Session parking:** Let idle sessions release their lock during Ctrl-Z so another terminal can resume them safely (#916)

### Improvements

- **Word-based wrapping:** Wrap composer input at word boundaries and preserve wrapped command-output styling across transcript views (#910, #913)
- **Terminal theme ownership:** Keep OSC 11 theme responses out of the composer, including late responses, forced themes, and incomplete sequences (#912, #914)
- **Resume guidance:** Clarify the recovery steps when another Fx process owns a session lock (#911)

### Bug Fixes

- **OAuth login:** Retry device authorization with the built-in client when a configured OAuth client is rejected as invalid (#915)
- **Suspend and resume:** Reacquire session ownership after Ctrl-Z and abandon cleanly if another process resumed the session (#916)
- **Terminal input:** Prevent theme protocol remnants from appearing as composer text after query timeouts (#912, #914)

### Contributors

- @fazxes
- @suarezesteban
- @willsather

## 0.3.47

### New Features

- **Queued prompt editing:** Add inline queued-prompt cards with navigation, editing, images, paste blocks, deletion, and batch submission (#901)
- **Terminal controls:** Support Ctrl-Z suspend/resume and Ctrl-D exit behavior while preserving draft and streaming semantics (#900)
- **Herdr integration:** Report Fx lifecycle state and pane identity to the Herdr agent multiplexer with opt-out support (#905)

### Improvements

- **Permission review:** Route automatic review outcomes through allow-or-ask behavior and preserve configured-rule and user denials (#907)
- **Session and command continuity:** Persist canceled command output across resume, consolidate resumable session paging, and preserve deferred tool state (#891, #894, #895, #898)
- **Runtime ownership:** Keep `/model` model-owned during active turns and centralize transcript domain notice styling (#897, #906)
- **Headless usage tracking:** Persist cumulative model token usage from headless `fx ask` sessions (#903)
- **Transcript and UI behavior:** Tighten turn-summary spacing and update rendering, resize, observer, and Gateway lifecycle contracts (#902)

### Bug Fixes

- **Undo restoration:** Restore overwritten destination contents when undoing rename and copy operations (#904)
- **File-mutation approvals:** Show the canonical external target in approval headers when a symlink redirects a write outside the workspace (#899)
- **Permission safety:** Avoid hard-denying automatic review results that require interactive confirmation (#907)
- **Session resume:** Preserve canceled command output and deferred tool state across resumed sessions (#895, #898)

### Contributors

- @fazxes
- @jsvana
- @scubbo
- @suarezesteban
- @dnukumamras

## 0.3.46

### New Features

- **Project and skill discovery:** Load applicable project instructions by target, discover duplicate skills from advertised locations, and support exact skill loading (#873, #881)
- **MCP transport and schemas:** Add NDJSON framing for MCP stdio transport and advertise MCP tools through the Gateway schema envelope (#857, #862)
- **Persistent session changes:** Preserve tracked changes across session resume and retain the saved OAuth issuer throughout OAuth sessions (#851, #852)
- **File and path workflows:** Improve external path classification and add focused `@` file-picker coverage (#884, #889)

### Improvements

- **Runtime ownership:** Consolidate agent, auth, permission, tool, context, and session behavior while removing obsolete adapters and dead contracts (#875, #879, #882, #883, #888, #890, #892)
- **Transcript and rendering:** Preserve transcript anchors, capped output, scrollback, lifecycle pins, and frame recovery across rewrites, retints, interruptions, and approvals (#850, #856, #859, #861, #863, #864, #867, #868, #870, #871, #874)
- **Authentication lifecycle:** Defer refresh until submission, validate revocation endpoints, revoke both OAuth tokens, and consolidate auth lifecycle handling (#848, #855, #866, #872)
- **Command and input behavior:** Isolate foreground command sessions, preserve auto-mode context, simplify the system prompt, and keep TUI input and command behavior consistent (#858, #875, #877, #878)
- **Test and benchmark coverage:** Expand fake Gateway, ACP, TUI, resize, file-picker, and command-output coverage for the current runtime paths (#850, #871, #880, #884)

### Bug Fixes

- **File picker:** Fix `@` file-picker correctness and tabbed-paste frame planning (#853, #884)
- **OAuth logout:** Fix prompt/logout races, validate revocation before use, and revoke both OAuth tokens (#848, #855, #866)
- **Image commands:** Fix pending image command submission (#846)
- **Command output:** Preserve canceled output, stabilize output anchors, and prevent live subagent viewer band overflow (#867, #868, #869, #870)
- **Terminal input:** Resolve plain Backspace under the Kitty keyboard protocol (#854)
- **Authentication sessions:** Discard empty sessions after API-key rejection and preserve the correct auth lifecycle (#876, #872)
- **MCP interoperability:** Correct MCP stdio framing and flattened tool-schema advertisement (#857, #862)
- **Subagent viewer:** Close the viewer on Escape and keep its live output within the available band (#849, #869)

### Contributors

- @fazxes
- @scubbo
- @jsvana
- @jimmyhmiller

## 0.3.45

### New Features

- **Configurable notifications:** Add configurable sound notifications for runtime events (#819)
- **ACP permission and output handling:** Surface ACP permission requests and strip ANSI escape sequences from ACP output (#837)
- **Ask command guidance:** Expose supported `fx ask` options through command help (#813)

### Improvements

- **Registry-owned context and sessions:** Route default, alternate, ACP, subagent, and session allowlist context through active registries (#816, #817, #822, #824, #828)
- **Permission decisions:** Preserve user intent, align decisions with the current request, expose explanations across runtimes, and retry malformed classifier output (#815, #823, #827, #832, #843)
- **Transcript and frame rendering:** Centralize transcript source preparation, make prompt and command-output admission atomic, preserve interrupted output, and make frame commits authoritative (#820, #825, #830, #834, #835, #838, #841, #844)
- **Authentication lifecycle:** Unify authentication failure output and cover the complete auth source lifecycle across CLI, ACP, and TUI flows (#818, #845)
- **Core runtime contracts:** Centralize context limits, simplify tool metadata, improve parallel read scheduling, and isolate E2E profile state (#821, #826, #829, #831, #833, #836)

### Bug Fixes

- **Large command output:** Fix the TUI freeze after receiving large command output (#842)
- **Logout failures:** Report failures when saved login credentials cannot be deleted and preserve API credentials when logging out of Fx (#839, #840)
- **Approval transcript handoff:** Preserve transcript scrollback through shell approvals and repair approval output handoff (#841)
- **Frame recovery:** Restore unfinished inline frame work after failed paint attempts (#838)
- **Auto-permission notices:** Fix notice ordering and keep explanations out of action labels (#832, #843)
- **Transcript cloning:** Prevent exponential `tool_details` capacity growth while cloning transcript state (#821)

### Contributors

- @fazxes
- @suarezesteban
- @jimmyhmiller
- @saxon-vercel

## 0.3.44

### New Features

- **Tool registry coverage:** Route browser, filesystem, command, search, launcher, MCP, question, and permission tool paths through focused registries (#742, #748, #750, #752, #755, #759, #762, #765, #775, #784, #788, #791, #796, #800, #810)
- **Authentication workflows:** Add explicit authentication source selection, an interactive auth source picker, unified auth status, and Keychain credential support for `fx ask` (#764, #769, #771, #779)
- **Context and session contracts:** Route interactive and default context through providers, preserve session transitions, and add resume command aliases (#763, #792, #797, #804)
- **Linux browser demo:** Add a browser-based Linux terminal demo with cached assets and a Vercel-hosted runtime surface (#514)

### Improvements

- **Runtime ownership:** Move auth onboarding, auth commands, OS context, file mutation input, and Gateway web-search policy into their owning runtimes or providers (#756, #774, #770, #790, #765, #789)
- **Permission and model safety:** Centralize auto-permission admission, preserve classifier results, pin auth sources to session credentials, and apply Gateway chat URL policy at app entry (#794, #795, #798, #802)
- **Transcript and rendering:** Improve full-transcript projection, viewport selection, alternate-screen recovery, scrollback preservation, atomic transcript writes, and Ctrl-O input handling (#743, #746, #747, #749, #753, #754, #757, #761, #772, #773, #799)
- **Authentication resilience:** Preserve prompts through login refresh and authentication flows, retain selected auth sources on failure, and refresh auth state consistently (#786, #789, #795, #801, #806)
- **Contract coverage:** Expand deterministic CLI, ACP, TUI, auth, image, Gateway, and command-output coverage for the current runtime paths (#787, #791, #803, #807, #808, #809, #811)

### Bug Fixes

- **Authentication recovery:** Preserve user prompts when login refresh or interactive authentication fails, and keep the selected auth source available for retry (#786, #795, #806)
- **Non-interactive startup:** Exit nonzero when interactive startup has no TTY instead of continuing with an invalid terminal state (#808)
- **Session resume:** Fix contended resume startup ordering and report session-store failures from `fx ask` (#783, #807)
- **Transcript persistence:** Make recorded transcript writes atomic and preserve normal transcript recovery across alternate screens (#772, #799)
- **History compaction:** Preserve UTF-8 content during compacted history writes (#777)
- **Command output:** Propagate `run_command` output handoff failures and lock live output behavior with contract coverage (#787, #793)
- **Slash picker:** Dismiss the slash picker reliably with Escape and keep auth-related slash menu waits covered (#803, #811)

### Contributors

- @fazxes
- @dnukumamras

## 0.3.43

### New Features

- **Built-in runtime ownership:** Move top-level commands, default turn context providers, Gateway capability/model catalog resolution, and file mutation proof checks into built-in or contract-owned modules (#725, #727, #728, #729, #731)
- **ACP and devbox contracts:** Route ACP methods through a typed dispatcher and wire devbox execution through provider contracts (#722, #726)
- **Ctrl-O transcript routing:** Add owned Ctrl-O full-transcript routing and centralize Ctrl-O transitions for the transcript detail path (#736, #738, #739)

### Improvements

- **Rendering and scroll accounting:** Clip retained transcript repaint windows, reconcile frame scroll commit receipts, attribute terminal movement rows, and repair split-state Ctrl-O rendering (#724, #730, #733, #736)
- **Permission and Gateway hardening:** Allow environment metadata checks in auto mode, detect wrapped secret reads, and restrict Gateway URL environment overrides to loopback hosts (#734, #735)
- **Ask and tool contracts:** Route ask plan mode through built-in modes and keep tool admission, Gateway catalog, and command surfaces under focused registries (#720, #727, #729, #731)
- **E2E and eval stability:** Repair deterministic E2E coverage and eval model selection so release checks cover the current runtime paths (#716)

### Bug Fixes

- **TUI submit ordering:** Fix TUI submit activity ordering so transcript activity is recorded in the expected order (#732)
- **Retained transcript clipping:** Clip retained transcript repaint windows to avoid stale repaint ranges leaking into active rendering (#724)
- **Ctrl-O split-state rendering:** Repair split-state rendering in the Ctrl-O detail runtime (#736)
- **Gateway URL overrides:** Restrict Gateway URL environment overrides to loopback hosts (#734)
- **Auto permission metadata:** Detect wrapped secret reads while allowing environment metadata checks in auto mode (#735)
- **E2E regressions:** Fix eval model selection and E2E regression coverage after the recent runtime migrations (#716)

### Contributors

- @fazxes
- @dnukumamras

## 0.3.42

### New Features

- **Built-in runtime migrations:** Move skills command handling, Gateway defaults, devbox command execution, Gateway web search, MCP runtime loading, and the context gather engine into built-ins (#705, #708, #709, #710, #713, #715)
- **Auto permission decisions:** Improve auto permission command decisions and detect bundled force-push flags in command requests (#719)
- **Worker render draining:** Defer frame commits during worker event draining so render updates are ordered through the worker path (#721)

### Improvements

- **Command output continuity:** Preserve split command output rows, preserve live command output positions, and guard the split command-output finalizer (#712, #717)
- **Active redraw planning:** Isolate active redraw repaint ranges and remove the obsolete affected repaint band (#711)
- **Upgrade progress output:** Simplify upgrade progress output while keeping the progress surface focused (#718)
- **Gateway and search ownership:** Move Gateway web search worker code and web search types under built-in/Gateway-owned boundaries (#710)

### Bug Fixes

- **Skills install cleanup:** Fix empty-result cleanup for `skills install` in the built-in skills command path (#708)
- **Split command output rows:** Preserve split command output rows and keep the finalizer from breaking command-output contiguity (#717)
- **Live command output positions:** Preserve live command output positions across transcript boundary handling (#712)
- **Active redraw clipping:** Isolate active redraw repaint ranges so stale repaint bands do not affect the active render window (#711)
- **Auto permission force-push detection:** Detect bundled force-push flags during auto permission decisions (#719)

### Contributors

- @fazxes

## 0.3.41

### New Features

- **Built-in MCP and skills:** Move MCP command/config handling, default skill roots, and skill installation into built-ins with file-scoped mutation helpers and owned contracts (#690, #696, #700, #701)
- **Built-in execution paths:** Move default context gathering, app tool labels, web fetch execution, and supplied-registry tool execution into built-in/runtime-owned paths (#683, #684, #688, #692)
- **Devbox execution provider:** Move the Vercel command backend into the devbox executor and route background support through host capabilities (#695, #697)
- **Auto permission request context:** Preserve request context for file mutations and pass it through auto permission decisions with clearer classifier prompting (#702)

### Improvements

- **Login and Gateway credentials:** Refresh `fx login` credentials for Gateway, poll the device flow immediately, and include an OAuth user agent (#703, #707)
- **Scrollback and footer layout:** Clarify frame scroll row splitting, reconcile scroll commit accounting, centralize frame scroll commit consumption, and cover tint footer contract edges (#693, #698, #706)
- **Output and snapshot contracts:** Share model catalog projection, doctor JSON rendering, model ID projection, empty task-list snapshots, and status/doctor snapshots (#681, #686, #691, #699, #704)
- **Tool schema and execution contracts:** Route tool schemas through core advertisement and route tool execution through the supplied registry (#687, #688)
- **MCP and skill ownership:** Keep MCP mutation helpers scoped and move install/root behavior out of broad runtimes into focused built-ins (#690, #700, #701)

### Bug Fixes

- **Tint footer spacing:** Fix tinted input footer spacing and add contract coverage for footer edge cases (#694)
- **Login polling:** Poll the `fx login` device flow immediately so the flow responds without waiting for the first interval (#707)
- **Gateway login credentials:** Refresh login credentials for Gateway before reuse (#703)
- **Auto permission decisions:** Improve auto permission command decisions and preserve subagent request context for file mutations (#702)
- **Vercel auth probes:** Remove unused Vercel credential probing and trim auth probe fields during devbox executor routing (#695)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.40

### New Features

- **Version flags:** Add top-level `--version` and `-v` handling with CLI coverage for the version surface (#667)
- **Built-in registries:** Move tool, slash-command, and mode registration into focused built-in registries so CLI, ACP, and agent paths share the same contracts (#648, #653, #655, #659, #663, #666, #680)
- **Host sandbox capability contract:** Add a host capability contract for sandbox support and route local command execution through the core execution router (#672, #676)

### Improvements

- **Rendering and scrollback pipeline:** Centralize command-output visibility, stable transcript retention, activity band planning, painted frame bands, retained transcript eligibility, terminal movement accounting, solved activity placement, fixed-point frame solving, rendered cell comparison, frame surface writes, transition accounting, frame retention checks, frame scroll phases, transcript transition retention, and retained frame area checks (#638, #640, #642, #643, #646, #647, #649, #652, #656, #658, #662, #665, #668, #670, #674, #679, #682)
- **Tool advertisement and dispatch:** Route tool advertisement through registry names, ask schema JSON through tool advertisement, read-only tools through the registry, subagent file tools through dispatch, and remove dead adapter capability plumbing (#655, #659, #673, #677)
- **Gateway and model ownership:** Move model catalog policy out of Gateway transport, tighten the catalog module boundary, unify Gateway HTTP result ownership, and share Gateway schema failure diagnostics in feedback reports (#644, #650, #675)
- **Permissions and ACP policy:** Centralize permission mode changes, trim dead permission-runtime test scaffolding, route auto-classifier checks through approval, and enforce ACP plan-mode tool policy (#641, #669, #685)
- **Command, config, and output contracts:** Route CLI JSON output through the shared writer, share detailed config layer merging, move slash command registration into built-ins, and constrain command prefix matching to registered entries (#671, #678, #680)
- **Input and text boundaries:** Move input gesture state onto `InputRuntime`, state full-transcript key handling, UTF-8 cut boundaries, and label wrapping policies once, and keep test/comment wording tighter (#637, #645, #654, #657, #661)

### Bug Fixes

- **Gateway credits UX:** Clarify Gateway credits access errors and keep HTTP result ownership in one place (#650)
- **Login setup routing:** Reopen the setup chooser from `/login` and simplify login command dispatch (#660)
- **Tool denial feedback:** Record denied TUI tools in feedback reports and share tool-call diagnostic recording (#664)
- **Input upgrade guard:** Restore the upgrade key-sequence guard after moving gesture state into `InputRuntime` (#637)
- **Auto approval prompts:** Tighten auto-approval prompt handling while routing auto permission checks through approval (#685)

### Contributors

- @fazxes

## 0.3.39

### New Features

- **Default auto permissions:** Make auto mode the default permission posture for new ask turns while keeping canonical lifecycle fixtures pinned to ask mode where needed (#634)
- **Image prompt adaptation:** Adapt image attachments for non-vision models with cached history images, cancellation handling, model capability resolution, and fake-gateway e2e coverage (#629)
- **Interactive upgrade handoff:** Add a Ctrl-R upgrade-ready handoff with staged upgrade runtime facts, shared helpers, and runtime-routed shortcut coverage (#631)
- **GLM 5.2 Fast default:** Set the compiled default model to `zai/glm-5.2-fast`, keep direct `fx ask` fallback in sync with interactive startup, and report the canonical `zai/glm-5.2` model while fast mode is enabled (1417bd4f)

### Improvements

- **Profile and settings config:** Respect profile and project configuration boundaries, share one settings parser across profile and project layers, and centralize config diagnostic metadata formatting (#616)
- **Input appearance:** Persist the input appearance preference and remember it in slash/input completions with tighter command test fakes (#619, #636)
- **Help and public wording:** Tighten top-level help output, simplify the welcome header, and polish public comments, docs, marketing copy, and test labels (#620, #622, #627, #628)
- **Hook and rendering ownership:** Centralize hook metadata lookup, move the Ctrl-O viewport and transcript paint pipelines into their owning runtimes, remove duplicate folded-expansion walks, and share CLI JSON line rendering (#621, #623, #625, #626, #630)
- **Scrollback and terminal movement:** Clarify terminal append ranges, centralize frame scroll acceptance, and share terminal movement row accounting for active scrollback rendering (#632, #633, #635)

### Bug Fixes

- **Transcript tool lifecycle rendering:** Keep tool lifecycle rendering stable in the transcript with provider visible-state cleanup and lifecycle verification (#624)

### Contributors

- @fazxes

## 0.3.38

### New Features

- **Auto-mode permission classifier:** Add a model-backed classifier for auto-mode tool admission with risk labels, file-context handling, denial summaries, and e2e coverage for command and file-tool decisions (#593)

### Improvements

- **Permission prompts and approvals:** Consolidate interactive permission prompting, share the approval review wrap walk, unify inline command approval measurement and paint, and dispatch amendment edits through one choice slot (#595, #598, #599, #607)
- **Hook runtime contracts:** Centralize hook definitions, common Stop checkpoint dispatch, dispatch metadata, dispatch state, action handling, tool preparation, runtime flow, PreToolUse lifecycle checkpoints, and Stop handler error coverage (#603, #605, #606, #608, #609, #610, #612, #613, #615)
- **Rendering and transcript projection:** Factor footer bottom reservation handling, simplify frame plan invalidation prep, share observer and measured-row projection walks, walk Ctrl-O geometry once, drop redundant Ctrl-O re-measurement, and align transcript paint line accounting with the paint walk (#597, #600, #602, #604, #611, #614, #617)

### Bug Fixes

- **Model picker Enter routing:** Keep Enter from binding hidden skills in the model picker and cover the persisted config path (#601)

### Contributors

- @fazxes

## 0.3.37

### New Features

- **Session resume metadata:** Store bounded metadata for saved sessions, show richer `/resume` rows with scope switching and previews, and hydrate stale picker rows without scanning the full store (#554)
- **CLI and composer shortcuts:** Add per-command `fx <command> --help` output and a composer shortcut catalog for editing actions including Ctrl-B/F, Ctrl-P/N, Ctrl-D, Alt-D, and backslash-Enter newline fallback (#570, #578)
- **Marketing landing page:** Launch the refreshed landing experience with a wider macOS-style terminal window and interactive `fx` shell demo powered by the new terminal components (#568, #569)

### Improvements

- **Rendering and input pipeline:** Move footer input composition, activity reservation, viewport selection, slash completion lookup, resize history targeting, frame wire composition, transcript transition resolution, and question panel measurement into clearer owners (#567, #571, #572, #573, #574, #575, #576, #583, #592)
- **Gateway and tool execution contracts:** Preserve model capability metadata, simplify Gateway streaming and SSE parsing, split turn tool-call execution paths, and model `web_fetch` results as a tagged union (#581, #584, #585, #587, #590, #591, #594)
- **Permission and tool plumbing:** Split file mutation proof validation, tool advertisement policy, sandbox output collection and chunk emission, file target policy evaluation, and tool dispatch prelude into named stages (#577, #580, #582, #586, #588, #589)

### Bug Fixes

- **Full transcript fallback:** Reuse the stored-result degradation policy so missing sidecars fall back through command artifacts and retained previews consistently (#566)

### Contributors

- @fazxes
- @jimmyhmiller
- @suarezesteban

## 0.3.36

### New Features

- **AI Gateway onboarding:** Add OAuth login plus Vercel CLI Gateway setup flows, including keychain-backed credentials, setup prompts, CLI docs, and setup diagnostics (#533, #546)
- **Model and permission controls:** Expose the full model catalog in the picker, feature Fable, and add `/permissions` argument autocompletion for `ask`, `auto`, and `reset` (#543, #557)
- **Input appearance:** Add an input style toggle across slash routing, footer paint planning, input presentation, and e2e coverage (#552)

### Improvements

- **Rendering pipeline:** Clarify frame building, footer frame assembly, skills-menu rows, footer invalidation, viewport selection, terminal movement, scroll planning, assistant wrapping, resize settling, visual layout scanning, VT state handling, and transcript preparation while removing an unused frame-grid copy path (#541, #542, #545, #547, #548, #549, #550, #553, #555, #556, #558, #559, #560, #561, #562, #563, #564)
- **Runtime and tool contracts:** Refactor skill-menu traversal, foreground command results, model capability routing, and `web_fetch` response framing into clearer owners (#537, #538, #539, #540)
- **E2E stability:** Stabilize render-lab, resize, permission, web-search, and eval helper expectations for the deterministic test suite (#551)

### Bug Fixes

- **TUI shutdown:** Cancel the file index during TUI shutdown so background indexing does not outlive the interactive session (#536)

### Contributors

- @fazxes
- @jimmyhmiller
- @suarezesteban

## 0.3.35

### Improvements

- **Transcript pipeline:** Split transcript source preparation, entry projection, full result streaming, assistant wrapping, visual measurement, status row state, frame movement, frame retention, and scrollback/runtime store contracts (#477, #481, #492, #494, #502, #510, #511, #522)
- **Footer and rendering surfaces:** Share footer projection, skills-menu projection, approval readiness, diff row formatting, footer invalidation, footer row text, resize coordination, and public wording cleanup (#473, #483, #487, #488, #497, #507, #516, #523)
- **Input and escape routing:** Split terminal-safe encoding, input escape parsing, resolved escape action routing, and input line deletion into focused owners (#498, #499, #517, #519)
- **Tool execution and result handling:** Share browser tool result mapping, large result preparation, `read_tool_result` execution, gateway schema capping, tool error detection, gateway error formatting, and status JSON rendering (#485, #500, #503, #504, #509, #527, #534)
- **Filesystem and workspace tools:** Simplify `copy_file`, `glob_files`, file-index raw paths, `file_info` date handling, stale path constraints, read-file selection, grep root dispatch, grep output notes, and grep candidate resolution (#472, #474, #479, #480, #482, #493, #501, #520, #521)
- **Command and CLI boundaries:** Centralize workspace settings mutation, opener adapters, context rules, shell command scanning, slash payload routing, command risk classification, unsupported `ask` flag parsing, and top-level help access (#476, #490, #491, #506, #513, #524, #525, #530)
- **Persistence and diagnostics:** Simplify task-log slicing, doctor session checks and counts, task/background record loading, and shared collection cleanup (#489, #495, #508, #512, #515, #528)
- **ACP and web argument contracts:** Simplify ACP JSON-RPC writer framing, semantic-search config, and `web_search` argument decoding (#478, #496, #505)

### Bug Fixes

- **Command status ordering:** Show command output status in the correct order and keep provisional status visible before streamed arguments arrive (#531, #532)
- **Queued prompts:** Preserve queued prompt transcript order and flush deferred summaries before rendering queued prompts (#529)
- **Ctrl-C cancellation:** Restore Ctrl-C exit behavior after active cancellation completes (#518)
- **Scrollback compaction:** Preserve the scrollback anchor when command output is compacted (#526)
- **Question and URL errors:** Tighten `ask_user_question` parser failures and `web_fetch` URL error contracts so invalid inputs report through the expected path (#484, #486)

### Contributors

- @fazxes

## 0.3.34

### New Features

- **Keychain onboarding:** Add macOS Keychain onboarding for AI Gateway credentials, including terminal output classification and graceful unavailable-keychain handling (#445)
- **Skills menu:** Add a structured skills menu with source-aware layout, bounded footer height, and composer skill-token search that preserves selected skill display spans on submit (#456, #458)

### Improvements

- **Gateway route recovery:** Retry replay-safe provider route failures and show recovery status inline, in turn summaries, and on wrapped status rows (#451, #461)
- **Runtime boundaries:** Move native clear probing, theme detection, terminal probe parsing, slash-command routing, background command notices, activity labels, diff row formatting, and `grep_files` dispatch into focused owners (#462, #463, #464, #465, #466, #467, #468, #470, #471)
- **Approval surfaces:** Clarify file approval screen layout and share footer surface planning across picker, approval, and input rendering (#459, #471)

### Bug Fixes

- **Model picker:** Fix model catalog requests so picker loading resolves correctly (#455)
- **Command approvals:** Keep command approval text fitted inline without breaking the review layout (#457)
- **Submitted paste:** Render the full submitted paste in the transcript instead of truncating accepted reflow rows (#460)
- **Slash picker footer:** Stabilize footer reservation and small-column slash picker rendering (#459)
- **Short terminal status:** Preserve the turn status row on short terminals and keep Space routed to the skills menu (#458, #461)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.33

### New Features

- **Ask-user shortcuts:** Submit predefined question choices by pressing their number while keeping the freeform option editable until Enter (#448)
- **Input tape diagnostics:** Capture raw terminal reads in opt-in input tapes so bracketed paste and other terminal input sequences can be replayed (#446)
- **Code block highlighting:** Add shared language profiles and infer common unlabeled JSON, shell, Python, SQL, Dockerfile, Go, Rust, and TypeScript snippets (#440)

### Improvements

- **Agent step limits:** Treat omitted and zero agent-step limits as unlimited across interactive turns, `fx ask`, ACP, and task-created subagents while preserving positive caps (#449)
- **Input runtime ownership:** Split interactive input handling into focused approval, completion, history, interrupt, paste, question, subagent, and submit runtimes without changing the existing facade (#444)
- **Command lifecycle rendering:** Keep large `run_command` activity and approval labels bounded while preserving full command review details and sending local shell scripts through private stdin pipes (#441, #447)

### Bug Fixes

- **Workspace sessions:** Scope CLI, ACP, and `/resume` session discovery to the current workspace while preserving exact-ID session loading (#452)
- **Prompt ordering:** Flush paced assistant text before user questions and later prompt cards so prompts do not cut into unfinished assistant output (#438, #450)
- **Approval input:** Prevent fragmented SGR and X10 mouse reports from cancelling active approvals, and keep long command review screens scrollable during worker polling (#442)
- **Footer pickers:** Fix footer picker row windowing and reverse scrolling across slash, session, model, and file pickers (#453)
- **Model listing:** Restore the `/models` TUI command and cancel background model-cache warmup during shutdown (#435)
- **Shell processes:** Reap exited blocked shell children so Linux zombies do not turn persistence failures into process-identity failures (#441)

### Contributors

- @fazxes

## 0.3.32

### Improvements

- **Model picker fast mode:** Keep model selection stable while `/fast` routes supported GLM models through their `-fast` request variant (#431)

### Bug Fixes

- **Resumed file diffs:** Persist completed file-edit presentation and restore both inline and `Ctrl-O` review diffs after session resume (#423)
- **Approval feedback:** Preserve feedback for its originating tool after parallel tool results complete (#436)
- **Terminal output safety:** Prevent command output from executing terminal controls in live and resumed transcripts (#429)
- **Transcript scrollback:** Preserve scrollback through status updates, resizes, and native clear recovery while correcting footer, status, and compact diff layout (#426, #427, #428, #430, #433, #434, #437)
- **Unavailable restored tools:** Mark saved tool results as failed when their backing result cannot be read (#432)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.31

### New Features

- **Fast marketing site:** Replace the homepage with a static manual-style landing page, separate documentation routing, and compatible social preview metadata (#413, #414, #419)
- **Completed file diff review:** Open the full completed `write_file` review diff in `Ctrl-O` while keeping the inline preview folded (#420)
- **Long command approval review:** Show wrapped long and multiline command approvals in the review screen without dropping the command text (#421)

### Improvements

- **Approval amendment input:** Accept bracketed paste in an active approval amendment draft without submitting a decision or overriding question prompts (#422)
- **Decision prompt pacing:** Pause queued assistant text while approval and question prompts are active, then resume it after the decision (#417)

### Bug Fixes

- **Session command replay:** Restore completed command output before its status and prevent duplicate command details in resumed `Ctrl-O` views (#415, #416)
- **Resumed question cards:** Rebuild saved question resolutions in the live card format without adding an extra `Asked` transcript row (#418)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.30

### New Features

- **Interactive session resume:** Add `/resume` to browse saved conversations without blocking the composer and switch through the same durable reconstruction path used at startup (#407)
- **Full transcript view:** Render persisted and live tool details in the scrollable `Ctrl-O` transcript while preserving inline scrollback and approval handoffs (#402)
- **Approval feedback:** Let Yes and No permission decisions accept a short instruction with Tab and deliver it after the matching regular, file, or sandbox tool result (#404)

### Improvements

- **File approval context:** Show five unchanged lines around each file diff hunk with exact omission markers, while keeping approval controls usable after inspection (#411)
- **Runtime modularity:** Split footer state and rendering, session storage, and assistant presentation into focused modules while preserving their existing contracts (#405, #408, #409)

### Bug Fixes

- **Session resume playback:** Restore transcript replay and completed command output when switching sessions, and keep streamed shell output lossless (#407)
- **Full transcript continuity:** Preserve question prompts, file approvals, compact inline output, and the normal screen when entering or leaving `Ctrl-O` (#402)
- **Welcome header spacing:** Remove the extra blank row before the welcome header without changing the composer spacing (#406)

### Contributors

- @fazxes

## 0.3.29

### New Features

- **Live terminal theme updates:** Refresh the interface when a supported terminal switches between light and dark themes, including existing transcript content and streamed inline code (#392)

### Improvements

- **Turn presentation:** Keep the thinking activity visible while paced assistant output drains, simplify completed summaries to elapsed time and tokens, and use a bold mathematical `f` in the welcome header (#389, #400, #401)
- **Upgrade feedback:** Show availability and known-size download progress on one terminal row with shorter completion text (#397)

### Bug Fixes

- **Resumed tool output:** Restore completed tool status and command output when resuming an interactive session, including safe visibility for malformed saved results (#399)
- **Question cancellation:** Handle physical and Kitty Escape keys in active question prompts, cancel the turn cleanly, and keep the next prompt independent (#393)
- **File approval mouse input:** Support legacy X10 wheel reports without allowing their bytes to cancel a pending file approval (#396)
- **Filesystem access recovery:** Return actionable guidance when inspection tools encounter operating-system access denials while preserving other permission and filesystem errors (#391)

### Contributors

- @fazxes

## 0.3.28

### New Features

- **Session replay recording:** Add `fx --record` for private terminal tapes in new and resumed interactive sessions, including `/feedback` attachments and resilient replay recovery (#384)
- **Richer Markdown transcripts:** Render autolinks, hard line breaks, indented code blocks, definition lists, lazy blockquote continuations, and referenced footnotes in the terminal (#358, #363, #366, #369, #372, #376)
- **File approval context:** Keep the transcript and full file review together in the scrollable approval screen (#374)

### Improvements

- **Read-only tool defaults:** Run web research, skills, tasks, snapshots, and screenshots without the default approval prompt while preserving explicit deny and ask rules (#386)
- **Web search routing:** Route explicitly allowed web searches through the selected model's Gateway provider tool across interactive, `fx ask`, ACP, and Web subagent flows (#356)
- **Terminal presentation:** Add a concise welcome header, top-align short file approvals, and render compact model settings in the footer (#370, #382, #383, #387)

### Bug Fixes

- **Session resume recovery:** Restore workspace-local history reliably through `--resume`, `--resume-last`, and exact session ID aliases while repairing invalid saved records safely (#367)
- **Repeated tool calls:** Let agents continue after repeated calls and tool failures instead of automatically ending the turn (#362)

### Contributors

- @fazxes

## 0.3.27

### New Features

- **Richer Markdown rendering:** Add underscore emphasis, syntax-highlighted and `~~~` fenced code, Setext headings, escaped punctuation, nested blockquotes, thematic rules, task-list continuation reflow, and inline image labels (#337, #342, #344, #345, #346, #348, #349, #353, #355)
- **Assistant transcript gutter:** Render assistant responses with a dedicated gutter for clearer transcript scanning (#339)
- **Generic tool review:** Present generic tool approval previews in the scrollable review screen (#343)

### Improvements

- **Terminal presentation:** Adapt submitted prompt cards to terminal colors and correct inline-code backgrounds in light terminals (#347, #351)
- **Web fetch decoding:** Decode compressed response bodies directly, preserve unsupported-encoding fallback behavior, and decode HTML entities in fetched titles (#352)
- **Runtime cleanup:** Remove redundant combined runtime-context wrappers (#341)

### Bug Fixes

- **Native terminal clear recovery:** Restore the Fx interface after native terminal clear operations such as `Cmd-K` (#338)

### Contributors

- @fazxes

## 0.3.26

### New Features

- **Rich Markdown transcripts:** Render responsive tables, fenced code blocks with language labels, headings, blockquotes, indented list continuations, inline code, links, and task lists in assistant responses (#321, #322, #323, #326, #328, #330, #331, #333, #335)

### Improvements

- **Assistant transcript layout:** Wrap prose at word boundaries and replay the full transcript after terminal resize to preserve readable output and scrollback (#325, #329)
- **Session replay ownership:** Separate session layout, log, and replay responsibilities while preserving session recovery behavior (#324)
- **Repetition guards:** Keep repeated tool-call protection internal while retaining its safety behavior across runtimes (#327)

### Bug Fixes

- **Composer word editing:** Correct word navigation and add `Ctrl-W` whitespace-delimited deletion in the interactive prompt (#332)

### Contributors

- @fazxes

## 0.3.25

### New Features

- **Full approval diffs:** Open write and edit approvals in a scrollable review screen so the entire proposed change remains available before a decision (#311)

### Improvements

- **Modular agent runtime:** Integrate the focused agent runtime stack and Hooks v1 while preserving interactive, `fx ask`, ACP, and subagent behavior (#317)
- **Tool status rendering:** Add lifecycle markers, bounded previews, and row-level UI observability for active, completed, failed, denied, and cancelled tool calls (#314, #319)
- **Streaming input:** Keep the input caret visible while a response streams, without exposing it in approval and question prompts (#312)
- **Resize recovery:** Rebuild the inline terminal after a settled resize to remove stale reflowed content while retaining Fx terminal modes (#318)

### Contributors

- @fazxes

## 0.3.24

### Improvements

- **Approval shortcuts:** Submit tool permission choices immediately with `1`, `2`, or `3`, while retaining arrow and Tab navigation with Enter confirmation (#308)

### Bug Fixes

- **Combining-mark terminal rendering:** Preserve zero-width combining suffixes through terminal repaint, frame diffs, resize, and transcript reflow without changing visual row geometry (#306)

### Contributors

- @fazxes

## 0.3.23

### Improvements

- **Hooks lifecycle foundation:** Add typed Hooks v1.0 `PreToolUse` and `Stop` contracts across interactive, `fx ask`, ACP, and subagents, with execution memory preserved through session replay, recovery, compaction, and export while keeping hook registrations disabled by default (#293)
- **Transcript resize integrity:** Centralize transcript transitions, anchor resize recovery to measured terminal movement, and preserve exact scrollback and intra-row repainting across rapid shrink and grow cycles (#294, #302)

### Bug Fixes

- **Tool argument recovery:** Apply one serialized JSON integrity check across Gateway admission, replay, and session loading, and repair malformed saved tool calls before projection across `fx ask`, ACP, resume, and legacy sessions (#292)
- **ACP prompt completion:** Publish terminal prompt responses only after workers become reapable so immediate follow-ups no longer race with cleanup or report `Prompt already in progress` (#300)
- **Resumed session reliability:** Keep saved `fx ask` model configuration alive through resumed state publication and let workspace-scoped `fx resume last` ignore unrelated stale commit boundaries while preserving errors for unresolved local candidates (#295, #303)

### Contributors

- @fazxes

## 0.3.22

### Improvements

- **Release preparation workflow:** Send AI Gateway changelog prompts with the required typed text content schema and validate generated payloads before dispatch (#297)
- **Approval resize regression coverage:** Exercise terminal resize after an accepted file write to keep the footer and process healthy while the turn continues (#287)

### Bug Fixes

- **Tool recovery integrity:** Reject conflicting streamed and final tool identities and malformed provider-executed arguments before dispatch, preserve exactly-once lifecycle status across parallel fallback and smart-stop finalization, sanitize malformed legacy session history, and safely flush incomplete ANSI or UTF-8 tails before lifecycle boundaries (#288)
- **Session persistence ownership:** Keep task and background persistence capabilities stable across interactive resume, saved `fx ask`, and ACP session moves, with transactional setup and cleanup on allocation or post-transfer failures (#289, #291)
- **Web search provider provenance:** Trust provider execution only for the exact Perplexity or Parallel tool advertised by the private search worker, matching live Gateway result events and rejecting malformed provider arguments (#296)

### Contributors

- @fazxes

## 0.3.21

### Improvements

- **File approval modal:** Replace compact prompt variants with one vertical modal that keeps bounded diffs, canonical decisions, equality disclosure, cancellation, and session grant choices consistent across resize, constrained terminals, and subagents (#285)
- **Activity benchmark organization:** Move the activity progress benchmark under `benchmarks/` with a narrow source export and aligned build and render-audit paths (#282)

### Bug Fixes

- **Streamed tool lifecycle ordering:** Correlate partial and final tool calls by exact call ID, flush queued assistant text before lifecycle rows, and report fatal interactive errors after terminal release (#283)
- **Malformed tool argument recovery:** Validate complete serialized arguments before admission, reject malformed local calls before permission or execution while allowing model repair, fail closed for provider-executed calls, and keep malformed bytes out of labels, traces, sessions, and outbound history (#284)
- **File approval safety:** Serialize affirmative file decisions against pending terminal resizes and reject structured grant roots containing active wildcard metacharacters before publishing the prompt (#285)

### Contributors

- @fazxes

## 0.3.20

### New Features

- **File edit approval previews:** Show bounded diffs before `write_file` and `edit_file` mutations, carry the reviewed change through the TUI, `fx ask`, subagents, and ACP, and apply approved writes atomically with stale-target revalidation (#274)

### Improvements

- **Unified terminal rendering:** Route tool lifecycle, transcript updates, and interactive frame commits through single owners, with stronger render-lab and benchmark coverage for progress, scrollback, and direct-write safety (#275, #279)
- **Reliable provider completion:** Keep conversational streams open through a valid terminal provider event, preserve caller-owned deadlines for web operations, and propagate length, error, cancellation, and malformed completion states consistently across `fx ask`, ACP, the TUI, and subagents (#278)
- **Release preparation workflow:** Restore the GitHub prepare-release workflow by fixing embedded heredoc parsing and keeping generated PR copy focused on release changes (#280)

### Bug Fixes

- **Resize, scrollback, and paste recovery:** Preserve welcome banners, user cards, scrollback, and large bracketed pastes while measuring the terminal cursor during resize, including delayed, ambiguous, and timed-out cursor replies (#279)
- **File mutation safety:** Revalidate file targets before replacement, preserve explicit write allowances for missing paths, keep approved no-op mutations prompt-free, and handle large consolidated Gateway tool calls (#274)
- **Provider and rendering lifecycle cleanup:** Reject duplicate tool identities, fail closed on invalid provider finishes, terminalize active status rows after errors, and fix transcript lifecycle reconciliation after map growth (#275, #278)

### Contributors

- @fazxes

## 0.3.19

### Bug Fixes

- **Quiet legacy preference startup:** Stop showing the legacy workspace-preference migration advisory during normal shell, CLI, and ask startup while retaining it in `fx doctor` without rewriting settings (#273)
- **Theme-safe user message cards:** Keep user messages readable across terminal appearance changes with explicit high-contrast foreground and background colors from the stable xterm grayscale palette (#276)

### Contributors

- @fazxes

## 0.3.18

### New Features

- **Global user preferences:** Persist model, reasoning effort, fast mode, output level, startup scrollback, prompt history, and statusline defaults across workspaces (#271)
- **Scoped allowlist management:** Keep ordinary allowlist rules workspace-local while supporting explicit user-scoped rules and source-aware views (#271)

### Bug Fixes

- **Legacy preference migration:** Move legacy workspace preference copies to global settings with private recovery snapshots while preserving project precedence and unknown settings (#271)

### Contributors

- @fazxes

## 0.3.17

### New Features

- **Numbered decision prompts:** Select approval and question options with number keys while keeping Enter as the explicit submit action (#266)
- **Effect-aware command permissions:** Run a narrow set of proven read-only commands directly while keeping Git, writes, network access, background work, dynamic shell behavior, and unsupported forms behind approval (#266)

### Improvements

- **Decision prompt input isolation:** Keep raw escape sequences and bracketed paste isolated from approval and question state, including freeform answers (#266)

### Bug Fixes

- **Native web fetch reliability:** Handle strict TLS close semantics, deterministic HTTP/1.x framing, absolute deadlines, cancellation, and multi-address fallback while preserving transport error causes (#265)
- **Model capability metadata:** Resolve effort, fast mode, adaptive thinking, and context limits from exact model IDs, share provider option serialization, and redact reasoning payloads from debug traces (#267)

### Contributors

- @fazxes

## 0.3.16

### New Features

- **Durable preferences and session memory:** Persist global and workspace settings, prompt history, schema-v3 session logs, saved ask/ACP/direct CLI resume, and managed task/background/result artifacts (#262)

### Improvements

- **Session observability and recovery:** Add doctor diagnostics, recovery E2E coverage, sparse-log benchmark fixtures, and user-facing session/config docs for durable storage (#262)
- **Internal cleanup:** Simplify command routing, tool adapters, MCP cleanup, web fetch, semantic search, transcript, and ACP helper paths (#260)
- **Benchmark guardrails:** Fail startup-budget checks when no benchmark result files are present and keep non-Linux timing runs informational (#263)
- **Background URL extraction:** Remove duplicate background URL scoring and reuse the shared shell command extraction path (#264)
- **Repository hygiene:** Remove the stray `permission-panel-test.txt` fixture from tracked files.

### Bug Fixes

- **Durable settings and sessions:** Harden symlink containment, malformed settings handling, legacy migration reporting, JSON error output, ACP cancellation, and read-only no-create paths (#262)

### Contributors

- @fazxes

## 0.3.15

### New Features

- **Home and external file paths** — Support `~/...` and lexical `../...` paths across file tools by canonicalizing targets before permission checks while keeping workspace-only glob containment intact (#258)

### Improvements

- **Internal cleanup** — Remove redundant command/output wrappers, duplicate session and tooling helpers, the unused legacy filesystem monolith, and narrow gateway and MCP declarations that are only used in-file (#257)
- **Startup benchmark stability** — Increase CI startup-latency samples so isolated runner stalls do not dominate the strict raw-mean budget (#258)

### Bug Fixes

- **Top-level upgrade** — Fixed `fx upgrade` failing with `failed to extract release archive` by initializing the upgrade command with real threaded I/O before spawning `tar`.

### Contributors

- @fazxes

## 0.3.14

### New Features

- **Startup scrollback setting** — Add config-backed startup scrollback, reserve startup viewport rows, and preserve transcript history during viewport growth (#237)

### Improvements

- **Filesystem and replay cleanup** — Deduplicate recursive directory creation, simplify replay error replies, and remove dead filesystem helper paths (#238, #240, #242)
- **Permission and session cleanup** — Reuse owned permission grant helpers, deduplicate session JSON path handling, and extract session grant persistence (#241, #243, #246)
- **Transcript and render cleanup** — Remove dead transcript forwarding, tighten VT diff handling, and keep the render-lab direct-write audit aligned with the production frame path (#244, #245)
- **MCP and ACP cleanup** — Reuse shared MCP cleanup helpers and remove unused ACP response helpers (#247, #248)
- **Native web hardening** — Tighten native web fetch and search routing, URL policy, permission behavior, diagnostics, artifact handling, and fake-gateway coverage (#250)
- **Fast mode persistence** — Keep queued turns fast from enqueue through worker execution and gateway requests, including supported provider options (#254)
- **Regression coverage** — Add focused tmux coverage for logical-line deletion, multiline arrow navigation, decision prompt input isolation, direct-write audits, and the active multiline tiny-resize matrix (#251, #252, #253, #255)

### Bug Fixes

- Fixed logical-line deletion in multiline input across raw, Kitty, and modified-key routes (#251)
- Fixed multiline arrow navigation for hard-newline, soft-wrapped, tabbed, narrow-pane, image-placeholder, and slash-picker input rows (#252)
- Prevented accidental typing, paste controls, false paste starts, and partial escape sequences from leaking into approval and question prompts (#253)
- Fixed active multiline input resizing at tiny valid heights, including hard-newline and soft-wrapped input at `8x5` through `8x8`, stale footer invalidations, and same-layout height-four recovery (#255)

### Contributors

- @fazxes

## 0.3.13

### New Features

- **Native web fetch** — Add `web_fetch` with strict URL policy, pinned HTTP transport, private extraction, cache reuse, progress reporting, diagnostics, and durable binary artifacts (#239)
- **Native web search** — Add `web_search` with private Gateway-backed search, permission gates, Web subagent support, and source diagnostics (#239)

### Improvements

- **Web tool coverage** — Add focused Zig, E2E, live, eval routing, and startup benchmark coverage for the native web paths (#239)

### Contributors

- @fazxes

## 0.3.12

### Bug Fixes

- Restored the v0.3.9 runtime baseline to remove regressions introduced by the UI v2 terminal pipeline while it is stabilized for a future release

### Contributors

- @fazxes

## 0.3.11

### Bug Fixes

- Fixed optimized interactive input rendering so typed characters remain visible in release builds

### Contributors

- @fazxes

## 0.3.10

### New Features

- **Render engine v2.1** — Route the interactive TUI through the UI v2 terminal pipeline with typed surfaces for the composer, footer pickers, command output, live tools, transcript history, and resize recovery (#231)
- **Render lab coverage** — Add UI v2 lab scenarios, terminal-pipeline analyzers, direct-write audits, replay coverage, and live smoke tests for approval, question, slash, resize, and render-gauntlet paths (#231)

### Improvements

- **Terminal frame stability** — Preserve intro rows, markdown code blocks, hyperlink spans, compact prompts, finished tool rows, and terminal exit frames while coalescing synchronized live updates (#231)
- **Input and picker routing** — Route model picker, file picker, slash completions, slash arguments, modal controls, bracketed paste, and composer submissions through the UI v2 input path (#231)
- **UI ownership cleanup** — Move render, terminal, transcript, footer, and input ownership into dedicated `src/core/` and `src/ui/` runtimes with shared contracts and row metadata (#231)

### Bug Fixes

- Fixed rename and copy tool labels so they show both the source and destination paths (#232)
- Retried gateway requests across DNS and network drops with cancellable reconnect status in the UI (#233)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.9

### New Features

- **Agent quality A/B harness** — Add a paired baseline/candidate eval runner for focused local-first routing scenarios, with deterministic helper coverage and artifact output for model-backed comparisons (#229)

### Improvements

- **Ask prompt UI** — Render `ask_user_question` prompts in the footer decision panel, keep ask activity out of transcript status rows, and write cleaner Q/A summaries after answers are submitted (#227)
- **Local-first workspace routing** — Strengthen the gateway prompt to inspect local files and local git before GitHub or provider tools for current-repo facts, with eval coverage for first-action routing (#229)
- **Write diff grouping** — Keep write/edit status rows in the execution path so batched mutation headers stay adjacent to their inline diffs instead of appearing early from streamed tool starts (#228)
- **Diff color tuning** — Use a softer removal color for inline diffs in light and dark themes (#226)

### Contributors

- @fazxes
- @Melkeydev

## 0.3.8

### New Features

- **Vertical slash command menu** — Render slash completions as a picker-style vertical menu with descriptions, clipping for narrow terminals, and regressions for navigation and command output cleanup (#224)
- **External file permissions** — Allow file tools to use explicit absolute paths through the existing permission policy, including config rules, session grants, and execution-time rechecks (#217)

### Improvements

- **Agent tool use and recovery** — Added shared context contracts, durable tool history, large result handles, normalized entrypoint context, retry handling, and eval matrix coverage for agent flows (#219)
- **GitHub routing** — Route checkout questions through local context first, GitHub metadata through `gh`, and broad web search last, with sanitized repo identity in turn context (#215)
- **Live token feedback** — Show live turn token estimates in the thinking shimmer and align generic thinking activity with the final turn summary gap (#222, #223)
- **Permission and status polish** — Refined permission approval prompts, approval caret handling, footer model labels, effort labels, and context status formatting (#220, #221)

### Bug Fixes

- Fixed footer overflow crashes for over-wide footer rows (#214)
- Fixed repeated inline scroll repaints when a planned scroll exceeds one terminal-height commit (#216)
- Preserved scrollback during shell shutdown footer cleanup (#218)

### Contributors

- @ctate
- @fazxes
- @Melkeydev
- @suarezesteban

## 0.3.7

### New Features

- **Persistent allowlist controls** — Added `/allowlist` for viewing, adding, removing, and resetting persistent command, tool, and URL allow rules, and persist `always` approvals into workspace-scoped permission rules (#188)
- **Unified agent harness** — Routed ask, ACP, and subagent flows through the same prompt assembly path, with runtime context refresh, permission-aware tool advertisement, structured tool errors, result caps, and MCP frame limits (#212)
- **Richer feedback reports** — Reworked `/feedback` into a local Markdown file attachment with gateway calls, tool calls, subagent activity, runtime state, permissions, transcript timeline, process metrics, and renderer snapshots (#190, #198)

### Improvements

- **Rendering runtime** — Moved transcript, footer, activity, and resize rendering through an explicit frame runtime pipeline with render-lab, replay, direct-write, resize, and stress coverage (#200, #201, #202)
- **Turn summary tokens** — Estimate current-turn token usage locally and show approximate token counts in the summary row (#203)
- **Default model** — Default fx to Opus 4.7, add Opus 4.7 capability metadata, and show automatic reasoning effort in the footer (#204)
- **Sandbox default** — Default command execution to `sandbox: none` unless users explicitly opt into `sandbox: os` (#210)
- **Recorder cleanup** — Removed recorder-backed pre-Fx capture, shell integration bootstrap, and recorder-specific repaint paths after the feature was superseded (#209)

### Bug Fixes

- Fixed permission prompt flow regressions in the approval UI (#207)
- Fixed long text wrapping in the CLI (#208)
- Fixed paste handling by adding a threshold for pasted input (#211)
- Removed an accidentally committed `.fx` session file (#205)

### Contributors

- @ctate
- @fazxes
- @Melkeydev
- @suarezesteban

## 0.3.6

### New Features

- **Pre-Fx terminal replay** — Added recorder-backed shell history capture and replay so fx can preserve terminal content that existed before launch across startup, relaunch, resize, and full-repaint paths (#192, #196)
- **Render Lab** — Added deterministic tmux and native-terminal render scenarios with byte replay, frame evidence, analyzer invariants, static reports, and stress coverage for terminal rendering regressions (#192)
- **ask_user_question freeform input** — Always offers a freeform slot in structured questions and treats it as a selectable placeholder instead of a separate sub-mode (#182)

### Improvements

- **Runtime layout** — Organized the active runtime under `src/core/`, `src/tools/`, and `src/ui/`, splitting transcript, footer, assistant, input, terminal, subagent, and render-engine code into owned modules (#191)
- **Transcript rendering** — Reworked inline transcript painting around a dedicated store, writer, painter, viewport runtime, activity overlay, command-output runtime, and expanded resize coverage (#187, #192)
- **Workspace search** — Added dedicated workspace file and grep-search runtimes with faster file listing, ignored-directory handling, context gathering, and tool adapter boundaries (#185)
- **Upgrade progress** — `fx upgrade` now streams download progress, holds the discovered-update state briefly, and reports clearer failure states for download, checksum, extraction, and binary replacement errors (#195)
- **Markdown links** — Rendered assistant links as OSC 8 hyperlinks with stable IDs across line wraps, cleaned hyperlink transitions, and removed the inline-code background highlight (#186)
- **TUI markers** — Refined prompt, assistant, and activity markers across the transcript, footer, render tests, and E2E expectations (#194)
- **Release signoff docs** — Added a Harbor eval runbook covering release gates, comparison runs, Terminal-Bench smoke/full jobs, artifact inspection, and pass criteria (#184)

### Bug Fixes

- **Model picker Enter** — Fixed Enter handling in the `/model` picker so the selected model path is accepted instead of leaving the picker stuck (#193)
- **Input caret paints** — Stabilized footer cursor painting and viewport positioning during input and resize paths (#184)
- **Pre-Fx replay clearing** — Fixed replayed terminal history being cleared at the wrong time during launch/relaunch rendering (#196)
- **TUI activity rendering** — Hardened activity rows, command output, background command updates, image/session/GitHub command output, and worker-event rendering against duplicate or stale transcript state (#187)

### Contributors

- @fazxes
- @suarezesteban

## 0.3.5

### New Features

- **Release eval harness** — Added a Harbor-based release evaluation suite with local `fx-release` and `fx-multistep` datasets, Terminal-Bench smoke/full job configs, comparison jobs for fx/Codex/Claude/OpenCode, Docker image tooling, readiness checks, run reports, publishing preflight docs, cloud sandbox notes, and RewardKit examples (#172)
- **Feedback command** — Added `/feedback` to copy a diagnostic report with version/build/platform, configuration, terminal metrics, MCP server state, interrupted-tool details, transcript tail, and trace-log tail for dogfooding reports (#177)
- **Status line controls** — Added `/statusline sandbox` and `/statusline context` toggles, persisted under `statusLine`, for optional sandbox and context-window usage in the footer (#178)

### Improvements

- **Tool status display** — Overhauled tool status rendering with gateway tool-start labels, replaceable transcript rows, active-line shimmer for long-running tool calls, completed-state text, and cleaner spacing around assistant output (#178, #179)
- **Output controls** — Persisted `/output` level changes, changed bare `/output` to show the current mode instead of toggling, and restyled command output and diff blocks in place when the mode changes (#178, #164)
- **Token and context telemetry** — Tracked gateway token usage, persisted session token totals, and mapped provider context-window sizes so the optional context status line can show real usage (#178)
- **Scrollback preservation** — Preserved pre-fx shell scrollback during startup, resize, and repaint; reserved rows for first paint; and pinned fx's owned top row across resize reanchors (#176, #181)

### Bug Fixes

- **Startup scrollback overflow** — Fixed scrollback behavior when startup output overflows the terminal viewport (#181)
- **Output command rendering** — Hardened `/output` command rendering across display modes, including replaceable output blocks, marker restoration, and resize paths (#164)
- **Shimmering status rows** — Fixed duplicate shimmering tool status rows in the transcript (#180)

### Contributors

- @ctate
- @fazxes
- @suarezesteban

## 0.3.4

### New Features

- **Kill ring** — Added Ctrl+K (delete to end of line) and Ctrl+Y (yank) for readline-style kill ring support (#171)

### Improvements

- **Welcome header** — Redesigned the welcome screen to show version, help hint, and feedback link inline next to the logo (#173)
- **Unlimited agent steps** — Removed the default 24-step hard cap; agents now run to completion, relying on doom-loop detection to catch stuck runs. A hard cap can still be set via `max_agent_steps` in settings or the `FX_MAX_AGENT_STEPS` environment variable (#174)

### Bug Fixes

- **Cmd+Delete positioning** — Fixed Cmd+Delete and Ctrl+U only deleting text left of the cursor instead of clearing the entire buffer; added Fn+Cmd+Delete for forward delete-to-end (#171)
- **Ctrl+V image paste** — Fixed Ctrl+V silently spawning osascript when the clipboard contains text instead of an image; now shows a message when no image is found (#171)
- **Image attachment cleanup** — Fixed orphaned image attachments remaining after delete-to-start and delete-to-end operations (#171)

### Contributors

- @ctate
- @suarezesteban

## 0.3.3

### New Features

- **Word deletion** — Added Option+Backspace and Option+Delete for word-by-word deletion in the input area (#167)

### Improvements

- **Keyboard navigation** — Added Cmd+Left/Right to jump to beginning/end of line, Cmd+Up/Down for history navigation, and Ctrl+A/E for readline Home/End bindings (#169)
- **Status bar cleanup** — Removed sandbox indicator from the status bar for a cleaner display (#165)
- **Core cleanup** — Standardized runtime ownership under `src/core/` (#166)
- **CDN distribution** — Added backfill workflow for auto-publishing releases to Vercel Blob and fixed blob uploads (#162, #163)

### Bug Fixes

- **Opt+Backspace in Kitty protocol** — Fixed Option+Backspace (ESC[127;3u) not triggering word deletion in Kitty keyboard protocol mode (#169)
- **Slash command trailing whitespace** — Fixed slash commands with trailing whitespace from tab-completion being rejected as unknown; no-argument commands like `/exit` no longer append a trailing space on completion (#168)

### Contributors

- @ctate
- @suarezesteban

## 0.3.2

### Improvements

- **Vercel Blob distribution** — Reverted install script and `fx upgrade` to fetch binaries from the public Vercel Blob CDN instead of GitHub Releases, eliminating `gh` CLI auth requirements and improving global download latency (#160)

### Contributors

- @ctate

## 0.3.1

### Improvements

- **Rename /diff to /output** — The `/diff` slash command has been renamed to `/output` for clarity, with display modes `normal`, `quiet`, and `off` (#156, #157)
- **Inline slash suggestions** — `/output` and `/sandbox` now show inline argument suggestions as you type (#158)

### Contributors

- @ctate

## 0.3.0
### New Features

- **Core runtime** — Added structured turn management and improved error handling across all tool categories (file, search, command, browser, skills, MCP) (#86 through #125)
- **ask_user_question tool** — Interactive modal for the agent to ask structured questions, with batch multi-question support (#82, #83)
- **Inline image placeholders** — Image attachments are represented as `[Image #N]` placeholders in the prompt input with atomic deletion and proper lifecycle management (#125)
- **Slash completions while working** — Slash command completions are now available even while the agent is actively running (#147)

### Improvements

- **GitHub Releases distribution** — Install script and `fx upgrade` now use the `gh` CLI for downloading releases, replacing the previous Vercel Blob pipeline (#152, #153, #154)
- **Structured transcript entries** — Transcript paint reshapes structured entries at display-width columns, fixing phantom blank rows on narrow-width resize (#76)
- **Worker event ownership** — Inline diff blocks route through the TUI worker event queue with hardened retention caps (#148, #149)
- **Sandbox modes** — Reduced public sandbox modes to `os` and `none` for clarity (#150)
- **Background command liveness** — Stopped background commands are now properly surfaced in agent context (#146)
- **Approval footer repaint** — Transcript repaints on footer height changes for correct approval UX (#135)
- **Tool call spacing** — Added spacing between consecutive tool calls for readability (#144)
- **Model selection** — Fixed `/model` to work on Enter and improved model picker behavior (#140, #81)

### Bug Fixes

- **Permission session persistence** — Fixed always/once approvals not persisting correctly across sessions (#141)
- **read_file not found** — Missing file paths in `read_file` now return proper failed tool results instead of crashing (#142)
- **History prompt ordering** — Locked down structural turn ordering to prevent prompt reordering bugs (#139)
- **Input edge navigation** — Up/Down arrow keys now jump to edges before recalling history (#138)
- **Logo color distortion** — Fixed color rendering on the fx logo (#143)
- **Duplicate skill loading** — Fixed duplicate same-session skill loading (#151)
- **Browser verification** — Required browser verification and fixed CDP target discovery (#145)

### Security

- **Symlink escape prevention** — Reject symlink writes outside the workspace (#130)
- **Bounded file traversals** — Atomic writes and bounded traversals for file tools (#131)
- **Command execution hardening** — Hardened command execution and background reuse (#132)
- **Search tool boundaries** — Hardened search tool boundaries and traversal limits (#136)
- **Browser/CDP hardening** — Structured error and artifact handling for browser tools (#133)
- **Permission denied payloads** — Structured `tool_permission_denied` error payloads (#135)
- **Step limit context** — Emit structured context at `step_limit_reached` (#126)

### Contributors

- @ctate
- @fazxes
- @Melkeydev
- @suarezesteban

## 0.2.10
### New Features

- **Inline markdown rendering** — Assistant text now renders rich markdown inline as it streams, including GFM pipe tables with aligned columns, borderless tables, horizontal rules, strikethrough, nested lists, and softened inline code styling (#52)
- **File editing diffs** — Tool output for file edits now shows collapsible code diffs with minimal and normal display modes; press Ctrl+O to expand or collapse folded output (#65)
- **Sandbox permission prompts** — When a sandboxed tool call is blocked (e.g. a package manager needing broader file access), fx now prompts the user to grant wider permissions instead of silently failing (#68)
- **Bracketed paste support** — Pasting multi-line text into the prompt is detected via bracketed-paste mode and represented as `[Pasted text #N, M lines]` placeholders (#52)

### Improvements

- **User message cards** — User messages in the transcript now render with a background bar for better visual separation (#58)
- **Streaming pacer SGR tracking** — The typewriter pacer now tracks SGR state so streamed styling (bold, color, etc.) survives footer resets (#55)
- **UI polish** — Improved footer layout, approval UX flow, and streaming display consistency (#55)
- **Text-to-tool gap** — Reduced blank space between assistant text and the first tool activity for a tighter layout (#66)

### Bug Fixes

- **Assistant pacer ANSI bugs** — Fixed a duplicate display-width import and two ANSI boundary bugs in the streaming pacer (#60)
- **Model picker reset** — Clearing the model picker filter now correctly resets the completion index (#59)
- **Transcript cursor math** — Made transcript cursor-position math ANSI-aware so styled rows are measured correctly (#58)
- **Image paste handling** — Image paths are now consumed at paste-time rather than render-time, with percent-encoded OSC 8 hyperlink paths in image badges (#57)
- **Bracketed paste state** — Moved bracketed-paste state from App to InputRuntime and clear prompt-history navigation on paste to prevent ghost state (#57)

### Contributors

- @ctate
- @fazxes
- @Melkeydev
- @suarezesteban

## 0.2.9

### New Features

- **@-mention file picker** — Type `@` at the start of a word in the TUI to open a fast workspace file picker with live filtering, Up/Down navigation, and Tab/Enter to insert the path. The index is built once in the background from `git ls-files` (with a directory-walk fallback) and queried with a basename-first substring scorer (#49)
- **Streaming typewriter pacer** — Assistant responses now tape out at a smooth, adaptive rate instead of flushing provider chunks verbatim, eliminating first-chunk flashes and cursor jitter during mid-render on terminals without DEC 2026 support (#50)

### Improvements

- **Zig 0.16 migration** — Migrated the codebase to Zig 0.16, adopting the new `std.Io` interface and Juicy Main entry signature (#48)
- **Render bug tooling** — Added an in-process VT emulator, deterministic resize unit tests, a tmux E2E resize suite, and `FX_RECORD` + `fx replay` for turning any user-reported render bug into a replayable tape (#53)

### Bug Fixes

- **TUI resize and approval rendering** — Removed alt-screen mode, fixed settled-resize viewport repaint so growing the window after a shrink restores fx's viewport without wiping pre-fx scrollback, and gave the approval prompt a dedicated row between the top divider and the input row (#53)
- **Kitty Ctrl+C during approvals** — Routed kitty-keyboard Ctrl+C (`\x1b[99;5u`) through the main escape decoder so it denies the pending tool call and keeps fx running instead of being silently swallowed (#53)
- **Slash command autocomplete** — Pressing Enter on a partial slash command (e.g. `/cl`) now completes to the suggested command instead of failing with "command not found" (#51)

### Contributors

- @ctate
- @Melkeydev
- @suarezesteban

## 0.2.8

### New Features

- **Docs site** — Added a full documentation site under the marketing app with search, table of contents, pagination, and expanded user-facing docs (#37, #38, #39, #41, #42, #43)
- **Bootup demo** — Added an interactive bootup demo component with real-time timer simulation to the landing page (#43)
- **/model picker** — Redesigned `/model` as a guided picker flow with background model preloading, typed filtering, effort and fast-mode support, and provider-aware capability checks (#36)

### Improvements

- **ACP and install script** — Improved ACP integration and install script for headless environments (#24)
- **Landing page** — Updated tagline, linked docs from the hero, and fixed installation URL (#38, #43)
- **Cross-compile CI** — Added cross-target compile checks for Linux and macOS on x86_64 and arm64 (#45)

### Contributors

- @ctate
- @Melkeydev
- @suarezesteban

## 0.2.7

### New Features

- **Background auto-upgrade** — fx now checks for updates in the background and shows upgrade availability in the status bar (#26)
- **/version command** — Added `/version` slash command to display the current fx version (#34)

### Contributors

- @ctate

## 0.2.6

### New Features

- **Marketing site** — Added marketing site under `apps/marketing` (#29)

### Improvements

- **Welcome screen polish** — Refined the welcome screen and footer hint styling (#27)
- **Startup benchmarks** — Added startup latency benchmarks with per-command budgets and CI enforcement (#25)

### Bug Fixes

- **Ctrl+X interrupt rendering** — Fixed Ctrl+X cancellation breaking transcript rendering (#32)

### Contributors

- @ctate
- @Melkeydev
- @suarezesteban

## 0.2.5

### Improvements

- **Inline CLI rendering** — Replaced the alternate-screen TUI with inline rendering that behaves like a standard CLI (#20)
- **Word jumping** — Added Option+Arrow word navigation in the input area (#19)

### Bug Fixes

- Removed **redundant /models command** that duplicated the /model list behavior (#18)
- Fixed **stray line** in output (#22)

### Contributors

- @ctate

## 0.2.4

- **Terminal cursor** — Shows a visible cursor in the TUI input area (#17)

## 0.2.3

- **Input bar redesign** — Replaced the solid input bar background with thin horizontal dividers (#16)

## 0.2.2

- **Light/dark theme detection** — Automatically detects terminal background color and selects the matching TUI theme (#15)

## 0.2.1

- Switched release builds to ReleaseSafe (#13)

## 0.2.0

- **fx upgrade** — Added `fx upgrade` command with minimal CLI output (#11)
- **/fast** — Added `/fast` slash command to toggle Anthropic fast mode (#10)
- CDN landing page and install script (#5, #6, #7, #8, #9)

## 0.1.0

- Initial release — interactive shell, permissions, sandbox, tools, ACP protocol, subagents (#1, #2, #3, #4)
