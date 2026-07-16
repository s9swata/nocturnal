# Simulation

Exercise Nocturnal without real Codex/Claude interactive sessions by feeding NDJSON fixtures into the live socket.

## Prerequisites

```bash
cd /path/to/nocturnal
swift build
```

Binaries land under `.build/debug/` (or `.build/<arch>-apple-macosx/debug/`).

```bash
# Convenience aliases (adjust arch if needed)
BIN=".build/debug"
# If missing:
BIN=$(echo .build/*-apple-macosx/debug)
```

## Live socket + NDJSON fixtures

There is **no in-app product demo mode**. Empty UI is expected until hooks or fixtures deliver sessions.

Terminal A — run the app:

```bash
swift run Nocturnal
```

Default socket:

```text
~/Library/Application Support/Nocturnal/ipc.sock
```

Override for isolation:

```bash
export NOCTURNAL_SOCKET="/tmp/nocturnal-sim.sock"
export NOCTURNAL_APP_SUPPORT="/tmp/nocturnal-sim-data"
mkdir -p "$NOCTURNAL_APP_SUPPORT"

# Terminal A
swift run Nocturnal

# Terminal B
BIN=.build/debug   # or .build/*-apple-macosx/debug
cat Fixtures/codex/session-started.ndjson | "$BIN/nocturnal-hook-forwarder"
cat Fixtures/codex/approval-required.ndjson | "$BIN/nocturnal-hook-forwarder"
cat Fixtures/codex/native-lifecycle-0.144.1.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source codex
cat Fixtures/claude/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source claude
cat Fixtures/opencode/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source opencode
cat Fixtures/opencode/native-bus-events.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source opencode
cat Fixtures/grok/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source grok-build
cat Fixtures/cursor/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source cursor

# Bad flags must not steal values (still exit 0 — fail-open):
"$BIN/nocturnal-hook-forwarder" --socket --timeout 1 </dev/null

# Setup: missing flag values are usage errors (exit 2), not silent defaults:
"$BIN/nocturnal-setup" install --product          # error
"$BIN/nocturnal-setup" install --forwarder        # error
"$BIN/nocturnal-setup" install --product codex --dry-run
"$BIN/nocturnal-setup" doctor --product codex
```

## Question / answer path

Feed a Codex-style `agent.question` envelope (or extend fixtures) then use the Answer sheet in the UI. Local response files land under Application Support `responses/`.

## Packaged app

```bash
Scripts/package_app.sh
export NOCTURNAL_SOCKET="/tmp/nocturnal-sim.sock"
open build/Nocturnal.app
# then pipe fixtures through build/Nocturnal.app/Contents/MacOS/nocturnal-hook-forwarder
```

Fixtures shipped in the app: `Contents/Resources/Fixtures/{codex,claude,opencode,grok,cursor}/`.

### Cursor live (hooks)

```bash
nocturnal-setup install --product cursor
# Open a Cursor Agent chat; sessionStart / tools / stop should appear as Cursor.
```

Simulate without Cursor:

```bash
cat Fixtures/cursor/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source cursor
```

### Grok Build live (hooks)

```bash
# With Nocturnal running and socket bound:
nocturnal-setup install --product grok
# Restart Grok so it loads ~/.grok/hooks/nocturnal.json
# Then use a session; SessionStart / tools / Stop appear in the pill.
```

Simulate without a live Grok process:

```bash
cat Fixtures/grok/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source grok-build
```

### OpenCode live (plugin)

```bash
# With Nocturnal running and socket bound:
nocturnal-setup install --product opencode
# Restart OpenCode so it loads ~/.config/opencode/plugins/nocturnal-bridge.js
# Then run a session; tool/session events should appear in the pill.
```

### OpenCode approvals (Phase 2)

In project or global `opencode.json`, require ask for tools you want to gate:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": "ask",
    "edit": "ask"
  }
}
```

When OpenCode prompts, Nocturnal should show **Approve**. Allow/Deny completes via
the plugin (socket decision → OpenCode permission API). Optional backup: Nocturnal
POSTs to `OPENCODE_SERVER` or `http://127.0.0.1:4096`.

### OpenCode recovery (Phase 3)

On launch, Nocturnal scans `~/.local/share/opencode/opencode.db` (and JSON
fallback under `storage/session/`) and injects idle `session.reconciled` rows.
Live plugin events still win for running state.

### Framework packaging notes (for maintainers)

- Empty `Contents/Frameworks/` is expected today (no third-party frameworks).
- Multi-arch packaging discovers framework **Mach-O** files with `file(1)`, not the execute bit — non-`+x` Mach-O payloads are still lipo’d and codesigned.
- A missing framework for one arch fails hard; the “multi-arch / partial-arch” second error line is only printed when `ARCHES` lists more than one architecture.
