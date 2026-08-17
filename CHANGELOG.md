# fx

## 0.0.1

<!-- release:start -->

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

<!-- release:end -->
