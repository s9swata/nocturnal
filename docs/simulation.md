# Simulation

Exercise Nocturnal without real Codex/Claude sessions.

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

## 1. Demo mode (UI only)

1. Launch the app (`swift run Nocturnal` or packaged `.app`).
2. Open the menu bar extra → **Demo Mode**.
3. Deterministic sessions from `DemoSessions.seedSessions()` appear, including:
   - running Codex-style session
   - idle Claude-style session
   - `waitingForApproval` (approve/deny sheet)
   - `waitingForInput` (question sheet — exercise answer UI without NDJSON)

No socket required.

## 2. Live socket + NDJSON fixtures

Terminal A — run the app (live mode, demo off):

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
swift run Nocturnal
```

Terminal B — forward fixture lines:

```bash
export NOCTURNAL_SOCKET="/tmp/nocturnal-sim.sock"   # match Terminal A

cat Fixtures/codex/session-started.ndjson \
  | "$BIN/nocturnal-hook-forwarder"

cat Fixtures/codex/approval-required.ndjson \
  | "$BIN/nocturnal-hook-forwarder"

cat Fixtures/claude/session-lifecycle.ndjson \
  | "$BIN/nocturnal-hook-forwarder"

# Unknown event (should not crash; metadata only)
cat Fixtures/codex/unknown-event.ndjson \
  | "$BIN/nocturnal-hook-forwarder"
```

Fail-open check (app stopped):

```bash
echo '{"v":1,"id":"00000000-0000-4000-8000-0000000000aa","source":"demo","eventType":"session.started","sessionId":"x","timestamp":"2023-11-14T22:13:20Z","payload":{},"raw":{}}' \
  | "$BIN/nocturnal-hook-forwarder"
echo "exit=$?"   # must be 0
```

## 3. Setup CLI (sandboxed)

**Never point tests at your real home.** Use a temp config root:

```bash
export NOCTURNAL_CONFIG_ROOT="/tmp/nocturnal-setup-test"
export NOCTURNAL_APP_SUPPORT="/tmp/nocturnal-setup-test/app-support"
export NOCTURNAL_SOCKET="/tmp/nocturnal-setup-test/ipc.sock"
mkdir -p "$NOCTURNAL_CONFIG_ROOT" "$NOCTURNAL_APP_SUPPORT"

"$BIN/nocturnal-setup" install --product all \
  --forwarder "$BIN/nocturnal-hook-forwarder"

"$BIN/nocturnal-setup" status --product codex
"$BIN/nocturnal-setup" uninstall --product claude

# Dry-run native merge (no product config writes)
"$BIN/nocturnal-setup" install --product all --mode merge-native --dry-run \
  --forwarder "$BIN/nocturnal-hook-forwarder"
```

Inspect:

```bash
find "$NOCTURNAL_CONFIG_ROOT" -type f
find "$NOCTURNAL_APP_SUPPORT/backups" -type f 2>/dev/null || true
```

### Raw Claude stdin wrap

```bash
echo '{"hook_event_name":"SessionStart","session_id":"raw-1","cwd":"/tmp"}' \
  | "$BIN/nocturnal-hook-forwarder" --wrap-source claude
```

## 4. Unit-level simulation (no UI)

```bash
swift test
# equivalent helper
Scripts/run_tests.sh
```

Swift Testing is provided via SPM (`apple/swift-testing`) so this works under
**Command Line Tools only** (no full Xcode / system XCTest required).

`DemoSessions.replaySimulation(into:)` applies deterministic envelopes inside tests.

Covered automatically:

| Area | Suite |
|------|--------|
| Codex / Claude / unknown decode | `EventDecodingTests` |
| State transitions + local responses | `SessionStoreTests` |
| Socket NDJSON round-trip | `SocketBridgeTests` (short `/tmp` paths) |
| Persistence + corruption quarantine | `PersistenceTests` |
| Hook install in temp roots only | `HookInstallerTests` |
| Response file routing | `ResponseRoutingTests` |

**Never** set `NOCTURNAL_CONFIG_ROOT` to your real home during tests.

## 5. Packaged app helpers

After `Scripts/package_app.sh`:

```bash
APP=build/Nocturnal.app
"$APP/Contents/Resources/Helpers/nocturnal-setup" status --product all
cat Fixtures/demo/seed-sessions.json >/dev/null  # also copied into Resources/Fixtures
```
