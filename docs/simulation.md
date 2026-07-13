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
cat Fixtures/claude/session-lifecycle.ndjson | "$BIN/nocturnal-hook-forwarder" --wrap-source claude

# Bad flags must not steal values (still exit 0 — fail-open):
"$BIN/nocturnal-hook-forwarder" --socket --timeout 1 </dev/null

# Setup: missing flag values are usage errors (exit 2), not silent defaults:
"$BIN/nocturnal-setup" install --product          # error
"$BIN/nocturnal-setup" install --forwarder        # error
"$BIN/nocturnal-setup" install --product codex --dry-run
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

Fixtures shipped in the app: `Contents/Resources/Fixtures/{codex,claude}/`.
