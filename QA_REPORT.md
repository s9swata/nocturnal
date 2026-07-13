# QA_REPORT — Nocturnal

**Author:** nocturnal-qa (follow-up cleanup)  
**Date:** 2026-07-13  
**Host:** macOS, Command Line Tools only (no full Xcode)  
**Swift:** Apple Swift 6.2.x (`swift build` / `swift test` under CLT)

---

## Summary

| Gate | Result |
|------|--------|
| `swift build` | **PASS** |
| `swift test` | **PASS** — **50 tests**, 8 suites |
| `Scripts/package_app.sh` | **PASS** → `build/Nocturnal.app` |
| `file` + `codesign -dv` | **PASS** (adhoc arm64) |
| Real `~/.codex` / `~/.claude` writes in tests | **None** |

### Follow-up items resolved (this pass)

1. **Core owns `NOCTURNAL_SOCKET`** — `PersistencePaths.resolve()` applies env override; AppModel no longer re-parses env; HookInstaller uses `paths.socketURL`.
2. **Question-sheet QA** — exercise via Codex/Claude fixtures + live socket (product demo mode removed).
3. **UI success copy** — “Recorded approval/denial/answer” (local file-drop; does not claim agent consumed response).
4. **`.orchestration/` gitignored** — prompt/run logs stay out of product; `.grok/agents` kept.
5. **Placeholder resource removed** — no `Resources/placeholder.txt`; fixtures still bundled via packaging script.

---

## Swift Testing under CLT

SPM dependency on `https://github.com/apple/swift-testing` (resolved **6.3.2**), product `Testing` on `NocturnalCoreTests`. Macros via swift-syntax; **no full Xcode required**.

Fixtures load from repo-root `Fixtures/` via `#filePath` walk (`TestSupport`).

---

## Test results (exact)

```text
$ swift test
…
✔ Suite EventDecodingTests passed …
✔ Suite SessionStateTests passed …
✔ Suite SessionStoreTests passed …
✔ Suite ResponseRoutingTests passed …
✔ Suite HookInstallerTests passed …
✔ Suite JSONValueTests passed …
✔ Suite PersistenceTests passed …
✔ Suite SocketBridgeTests passed …
✔ Test run with 50 tests in 8 suites passed after 0.248 seconds.
```

Exit code **0**.

### New / updated coverage (this pass)

| Area | Tests |
|------|--------|
| Socket env override | `PersistenceTests/resolveHonorsExplicitSocketOverride` |
| Socket default under root | `PersistenceTests/resolveDefaultsSocketUnderAppSupportRoot` |
| Testing isolation | `PersistenceTests/testingHelperIgnoresProcessEnvironment` |
| Replay includes question | `SessionStoreTests/replaySimulationAppliesEnvelopes` |
| HookInstaller uses Core socket | `HookInstallerTests/resolveHonorsConfigRootEnvironment` |
| Obsolete settings key | `PersistenceTests/settingsDecodeToleratesObsoleteDemoModeKey` |

Short-path safeguards preserved: `SocketPaths.makeShortTestingRoot`, `SocketPaths.testingSocketPath`, `TestSupport.makeShortSocketRoot` under `/tmp`.

---

## Coverage map

| Required area | Suite / tests | Status |
|---------------|---------------|--------|
| Event decoding (Codex) | `EventDecodingTests` + fixtures | Pass |
| Event decoding (Claude) | lifecycle, notification, PreToolUse matrix | Pass |
| Unknown raw metadata | decoder + `SessionStoreTests` | Pass |
| State transitions | lifecycle, approval, question, local response | Pass |
| Socket bridge round-trip | `SocketBridgeTests` (short `/tmp` paths) | Pass |
| Persistence load/save | `PersistenceTests` | Pass |
| Persistence corruption | quarantine + skip | Pass |
| Socket path resolution | env override + default + testing helper | Pass |
| Hook installation temp-only | `HookInstallerTests` | Pass |
| Response routing | file sidecars, multiplex, e2e | Pass |
| Fail-open forwarder | `JSONValueTests` + socket forwarder test | Pass |

### Gaps (not automated)

| Gap | Notes |
|-----|--------|
| SwiftUI / AppKit UI | No UI test runner under CLT; manual per `UI_HANDOFF` / fixtures |
| Jump-back strategies | Needs mock openers / NSWorkspace |
| Native merge golden files | Vendor shapes still evolving |
| Packaged app launch UI | Not automated; binary + codesign verified |
| Forwarder process exit code | Manual in `docs/simulation.md` (library path covered) |

---

## Packaging verification

### Command

```bash
Scripts/package_app.sh
```

Exit **0**. Output path:

```text
Created …/build/Nocturnal.app
```

### `file`

```text
build/Nocturnal.app/Contents/MacOS/Nocturnal: Mach-O 64-bit executable arm64
build/Nocturnal.app/Contents/Resources/Helpers/nocturnal-hook-forwarder: Mach-O 64-bit executable arm64
build/Nocturnal.app/Contents/Resources/Helpers/nocturnal-setup: Mach-O 64-bit executable arm64
```

### `codesign -dv build/Nocturnal.app`

```text
Executable=…/build/Nocturnal.app/Contents/MacOS/Nocturnal
Identifier=app.nocturnal.Nocturnal
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=5840 flags=0x2(adhoc) hashes=172+7 location=embedded
Signature=adhoc
Info.plist entries=13
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=10
```

Helpers are adhoc-signed as well.

### Bundle checklist

| Item | Value |
|------|--------|
| Bundle id | `app.nocturnal.Nocturnal` |
| Marketing version | `0.1.0` (`version.env`) |
| Build number | `1` |
| `LSUIElement` | `true` (`MENU_BAR_APP=1`) |
| Helpers | `Contents/Resources/Helpers/` + `Contents/MacOS/` |
| Fixtures | `Contents/Resources/Fixtures/{codex,claude}` |
| Placeholder resource | **Removed** (no `placeholder.txt`, no SPM resource bundle) |
| Arch | arm64 (host) |

---

## Peer reviews

| File | Subject |
|------|---------|
| [`docs/reviews/qa-on-core.md`](docs/reviews/qa-on-core.md) | Core — socket single-source **resolved** |
| [`docs/reviews/qa-on-ui.md`](docs/reviews/qa-on-ui.md) | UI — copy + dual-resolution **resolved** |

---

## Commands reference

```bash
swift build
swift test
Scripts/run_tests.sh
Scripts/package_app.sh
file build/Nocturnal.app/Contents/MacOS/Nocturnal
codesign -dv --verbose=4 build/Nocturnal.app

# Simulation (see docs/simulation.md)
export NOCTURNAL_SOCKET=/tmp/nocturnal-sim.sock
export NOCTURNAL_APP_SUPPORT=/tmp/nocturnal-sim-data
export NOCTURNAL_CONFIG_ROOT=/tmp/nocturnal-setup-test
```

---

## Known limitations

1. **CLT / Xcode:** Swift Testing works via SPM dependency; system XCTest still unavailable without Xcode.
2. **UI tests:** None automated (question sheet exercised via fixtures + socket).
3. **Socket path length:** Use short paths under `/tmp` for sim and tests (`SocketPaths.makeShortTestingRoot`).
4. **Adhoc signing only** — not notarized; Gatekeeper may warn on other machines.
5. **Cold `swift test`** downloads/builds swift-testing + swift-syntax once.
6. **Stale SPM resource bundles:** after removing target resources, delete leftover `.build/**/Nocturnal_Nocturnal.bundle` before packaging if an old incremental build left one behind.

---

## Done criteria

1. Automated tests run and pass (`swift test`) — **yes (50)**
2. Package script produces `build/Nocturnal.app` — **yes**
3. `file` + `codesign` verification recorded — **yes**
4. Bounded follow-ups (socket SSoT, fixtures, UI copy, gitignore, placeholder) — **yes**
5. `QA_REPORT.md` complete — **yes**
6. No commit performed — **yes**
