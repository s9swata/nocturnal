# CORE_HANDOFF — NocturnalCore production MVP

**Author:** nocturnal-core  
**Date:** 2026-07-13  
**Status:** Production MVP implemented; `swift build` clean.

---

## What landed

| Area | Status |
|------|--------|
| `EventSocketServer` / `EventSocketClient` | Multi-client NDJSON, cancel-safe stop, connect timeout, diagnostics, line size cap |
| `SessionStore` | Cap/prune policy, hydrate + auto-persist, local response apply, unknown metrics |
| Decoders | Codex + Claude implemented sets; `EnvelopeNormalizer` for raw stdin; unknown → raw metadata |
| Persistence | Atomic JSON sessions/settings; corrupt quarantine; injectable `PersistencePaths` |
| `HookInstaller` | Sidecar + optional native merge; dry-run; `configRoot` injectable |
| `FailOpenHookForwarder` + CLI | Always exit 0; `--wrap-source`; connect timeout |
| `ResponseTransport` | File + agent sidecars + in-memory + multiplex |
| `JumpBackCoordinator` | Codex / Cursor / VS Code / Ghostty / iTerm2 / Terminal / Finder; AppleScript tab focus; fail-soft reasons |
| Demo | `DemoSessions` + fixture file discovery |
| CLIs | Setup install/uninstall/status + `--mode` + `--dry-run`; forwarder flags for simulation |

---

## Public API for UI (`AppModel`)

### Bootstrap

```swift
let paths = try PersistencePaths.resolve() // honors NOCTURNAL_APP_SUPPORT
let persistence = SessionPersistence(paths: paths)
let store = SessionStore(persistence: persistence)
await store.hydrate(from: persistence)

let settingsStore = SettingsStore(paths: paths)
let settings = try await settingsStore.load()

let server = EventSocketServer(path: paths.socketURL)
let stream = try await server.start()
for await envelope in stream {
    _ = await store.apply(envelope)
}
```

Or:

```swift
let runtime = try NocturnalCore.makeRuntime()
```

### Observation

```swift
let stream = await store.snapshots() // yields SessionStoreSnapshot (current first)
let snap = await store.currentSnapshot()
// snap.sessions, snap.revision, snap.unknownEventCount, snap.sessionsNeedingAttention
```

### Mutations (UI must not edit session maps directly)

| Intent | API |
|--------|-----|
| Live event | `await store.apply(envelope)` |
| Approve / deny | write via `ResponseTransporting.submit(.approval)` then `await store.applyLocalResponse(...)` |
| Answer question | same with `.question` |
| Demo load | `await DemoSessions.load(into: store)` with `SessionStorePolicy(autoPersist: false)` |
| Jump back | `JumpBackCoordinator().jump(using: session.jumpBack ?? JumpBackContext(workingDirectory: session.workingDirectory))` |
| Settings | `SettingsStore.load()` / `save(_:)` |

### Key models (all `Sendable`)

- `Session`, `SessionID`, `SessionState`, `AgentSource`
- `EventEnvelope`, `JSONValue`
- `ApprovalRequest`, `QuestionPrompt`, `AgentResponse`, `ApprovalDecision`, `QuestionAnswer`
- `JumpBackContext`, `JumpBackResult`
- `AppSettings`, `SessionStoreSnapshot`, `SessionStorePolicy`
- `HookInstallResult`, `HookProduct`, `HookInstallMode`

### Implemented event types

Documented in `docs/HOOK_SCHEMAS.md`. Source of truth sets:

- `CodexEventDecoder.implementedEventTypes`
- `ClaudeEventDecoder.implementedEventTypes`

Unknown events: `DecodedEvent.isUnknown == true`, metadata preserved, **no crash**.

---

## Test seams for QA

| Seam | How |
|------|-----|
| Config root | `HookInstaller(configRoot: tempURL, …)` or `NOCTURNAL_CONFIG_ROOT` |
| App Support | `PersistencePaths.testing(temporaryDirectory:)` or `NOCTURNAL_APP_SUPPORT` |
| Socket path | `SocketPaths.testingSocketPath(in:)` / `NOCTURNAL_SOCKET` |
| Responses | `InMemoryResponseTransport` |
| Decode | inject `EventDecoding` into `SessionStore` |
| Jump-back | inject `[any JumpBackStrategy]` into `JumpBackCoordinator` |
| Forwarder | `FailOpenHookForwarder(options:)` — no process spawn required |
| Demo | `DemoSessions.seedSessions()` / `replaySimulation(into:)` |
| Socket diagnostics | `await server.currentDiagnostics()` |
| Decode metrics | `CompositeEventDecoder.currentMetrics()` |

### Environment variables

| Variable | Purpose |
|----------|---------|
| `NOCTURNAL_SOCKET` | Unix socket path |
| `NOCTURNAL_APP_SUPPORT` | Persistence root |
| `NOCTURNAL_CONFIG_ROOT` | Setup CLI config sandbox |
| `NOCTURNAL_FORWARDER_DEBUG` | Forwarder stderr |

**Never** run setup tests against the real home without `NOCTURNAL_CONFIG_ROOT`.

### CLT / Xcode note

On Command Line Tools only, `import XCTest` and `import Testing` are unavailable, so `swift test` cannot link. Tests under `Tests/NocturnalCoreTests` remain for full Xcode. Prefer migrating to Swift Testing when Xcode is present (`swift-testing-pro`).

---

## Simulation (smoke-verified)

See `docs/simulation.md`. Verified in sandbox:

```bash
export NOCTURNAL_CONFIG_ROOT=/tmp/nocturnal-setup-test
export NOCTURNAL_APP_SUPPORT=/tmp/nocturnal-setup-test/app-support
export NOCTURNAL_SOCKET=/tmp/nocturnal-setup-test/ipc.sock
nocturnal-setup install --product all --forwarder …   # exit 0
nocturnal-setup install --mode merge-native --dry-run  # no writes beyond dry-run messaging
echo '…' | nocturnal-hook-forwarder                    # exit 0 even if socket missing
```

---

## Open contracts (remaining)

1. **Codex deep link scheme** — strategy opens whatever URL events provide; production scheme not vendor-confirmed (`codex://` assumed).  
2. **Native hook merge** — best-effort JSON shapes for `.codex/hooks.json` and `.claude/settings.json`; may need adjustment when real products change.  
3. **Response consumption** — agents must poll `responses/` (or a future plugin); no reply socket yet.  
4. **Envelope versioning** — `EventEnvelope.currentSchemaVersion == 1`; bump policy on breaking wire changes.  
5. **Claude raw stdin** — normalizer covers common fields; full vendor matrix still evolving.

---

## Peer review

`docs/reviews/core-on-architect.md` — contract nits fixed vs remaining.

---

## Suggested UI next steps

1. Wire attention sorting from `snapshot.sessionsNeedingAttention`.  
2. Approval/question sheets → `approve` / `answer` already on `AppModel`.  
3. Surface `statusMessage` + socket path for diagnostics.  
4. Respect `AppSettings.reduceMotion` + system Reduce Motion.  
5. Keep all session mutation inside `SessionStore` (façade only).
