# Nocturnal

Local-first macOS companion for AI coding agents (Codex & Claude Code).

- Free, offline, no accounts or telemetry  
- Menu bar + optional floating pill  
- Fail-open hooks over a Unix domain socket  
- Quiet nocturnal UI (see `.impeccable.md`)

## Requirements

- macOS 14+  
- Swift 6.2+ toolchain  
- **Command Line Tools are enough** for `swift build`, `swift test`, and packaging  
  (full Xcode is optional)

## Build

```bash
git clone <repo-url> nocturnal
cd nocturnal
swift build
```

## Tests

Tests use **Swift Testing** via an SPM dependency on
[`apple/swift-testing`](https://github.com/apple/swift-testing) so they run under
Command Line Tools without XCTest.

```bash
swift test
# or
Scripts/run_tests.sh
```

Coverage includes event decoding, session state transitions, socket bridge
round-trips (short `/tmp` paths), persistence load/save/corruption, hook install
in **temp directories only**, and response routing.

**Never** point setup/hook tests at real `~/.codex` or `~/.claude` — use
`NOCTURNAL_CONFIG_ROOT` (tests inject temp roots automatically).

## Run the app

```bash
swift run Nocturnal
```

Or package a `.app` bundle:

```bash
Scripts/package_app.sh
open build/Nocturnal.app
```

The package script:

- Builds **Nocturnal**, **nocturnal-hook-forwarder**, and **nocturnal-setup**
- Emits **`build/Nocturnal.app`** with `LSUIElement` (menu bar companion)
- Copies helpers to `Contents/Resources/Helpers/` and `Contents/MacOS/`
- Bundles `Fixtures/` for offline demo/simulation
- Ad-hoc signs the bundle (`codesign --sign -`)

Verify:

```bash
file build/Nocturnal.app/Contents/MacOS/Nocturnal
codesign -dv --verbose=4 build/Nocturnal.app
```

## Demo mode

1. Launch Nocturnal  
2. Menu bar → **Demo Mode**  
3. Deterministic sample sessions appear (no agents required)

## Simulation (hooks without real agents)

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
```

Full recipes: [`docs/simulation.md`](docs/simulation.md).

## Install agent hooks (careful)

Setup writes **Nocturnal-managed sidecars** only. Prefer a sandbox root while developing:

```bash
export NOCTURNAL_CONFIG_ROOT="/tmp/nocturnal-setup-test"
export NOCTURNAL_APP_SUPPORT="/tmp/nocturnal-setup-test/app-support"
mkdir -p "$NOCTURNAL_CONFIG_ROOT" "$NOCTURNAL_APP_SUPPORT"

swift run nocturnal-setup -- install --product all
swift run nocturnal-setup -- status
```

See [`docs/HOOK_SCHEMAS.md`](docs/HOOK_SCHEMAS.md) for implemented event types.

## Architecture

| Module | Role |
|--------|------|
| `NocturnalCore` | Models, session store actor, socket, decode, persist, jump-back |
| `Nocturnal` | SwiftUI app shell |
| `nocturnal-hook-forwarder` | stdin → socket (always exit 0) |
| `nocturnal-setup` | Idempotent hook install/uninstall |

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · agent handoff: [`ARCHITECT_HANDOFF.md`](ARCHITECT_HANDOFF.md) · QA: [`QA_REPORT.md`](QA_REPORT.md)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
