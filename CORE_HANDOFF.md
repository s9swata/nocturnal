# CORE_HANDOFF — NocturnalCore production MVP

**Author:** nocturnal-core  
**Date:** 2026-07-13  
**Status:** Production MVP + review-fix pass; `swift test` green (156 tests).

---

## What landed

| Area | Status |
|------|--------|
| `EventSocketServer` / `EventSocketClient` | Multi-client NDJSON; **off-actor client reads**; cancel-safe stop (**`shutdown` + close** idle clients); `SO_NOSIGPIPE` |
| `SessionStore` | Cap/prune; **stale events never rewind/revive terminal or promote ordering**; mismatched approval/question IDs are no-ops; `replaceAll` last-wins without trap |
| Decoders | Codex + Claude implemented sets; metrics by **inferred** source; epoch timestamps via shared parser (**≥ 1e12 = ms**); incomplete envelope fast-path rejected; malformed/`v` uses `exactIntValue` fallback |
| Persistence | Atomic JSON; corrupt quarantine; **`deleteAll` removes regular non-symlink files only**; disjoint **`records/`** path namespace + case-stable encoding |
| `ResponseTransport` | Envelope + **subdir sidecars** (`codex/`, `claude/`, `answer/`) — no flat namespace collision with `codex-x` |
| `JumpBackCoordinator` | Codex schemes allowlisted (`codex`, `openai-codex`); AppleScript on **MainActor** |
| Settings | Schema v2; **never downgrade/rewrite newer schema (e.g. 99)**; load is read-only; **`update(_:)` / `canSave()`** for safe UI writes |
| Socket paths | `NOCTURNAL_APP_SUPPORT`; **explicit > env > default**; no eager App Support create when socket override set |

---

## Migration / compatibility notes (2026-07-13 robustness pass)

1. **Session / response filenames** use a disjoint **`records/`** subdirectory for canonical writes plus **case-stable** `PathComponentEncoding` (uppercase ASCII is percent-encoded). Reads try: `…/records/<body>` → flat prior `n.<body>` → flat unprefixed percent-encode → legacy `/`+`:` → `_` sanitize. New writes never use a flat `n.` filename prefix (that layout collided: id `foo` → `n.foo.json` vs literal id `n.foo`). **Embedded `Session.id` is authoritative** before any migrate/delete; migration never overwrites a foreign canonical record.
2. **Response sidecars** live under `responses/codex/<encoded>.json` (same for `claude/`, `answer/`). Envelopes live under `responses/records/`.
3. **Settings:** loading a schemaVersion `> current` leaves the file untouched; `SettingsStore.save` throws `newerSchemaOnDisk`. Older schemas migrate in-memory only (no save-on-load). Prefer `settingsStore.update { … }` over mutate-then-`try? save`. **UI (`AppModel.updateSettings`) assigns published settings only after a successful update.**
4. **Claude `permission_mode`:** only `ask` / `default` / `prompt` create approvals; `none` / `off` / `allow` / `bypassPermissions` / `acceptEdits` / etc. do not.
5. **`sourceRaw`** is preserved across encode/decode hops when present.
6. **`JSONValue.exactIntegerString`** returns `nil` outside exact `Int64` (no `String(format:)` fallback).

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
| Jump back | `JumpBackCoordinator().jump(using: session.jumpBack ?? JumpBackContext(workingDirectory: session.workingDirectory))` |
| Settings | Prefer `SettingsStore.update { … }` (or `canSave()` + `save` with catch). **Never** optimistic mutate + `try? save` |

### Settings UI contract (`AppModel.updateSettings`)

Core refuses future-schema overwrites (`SettingsStoreError.newerSchemaOnDisk`).
**App must not** optimistically mutate published settings then `try? save`.
`AppModel.updateSettings` loads, mutates on MainActor, then `settings = try await store.save(next)`
and surfaces `SettingsStoreError` on `statusMessage` without changing UI state on failure.

Core regressions: `settingsSaveRefusesToOverwriteNewerSchema`, `settingsUpdateRefusesNewerSchemaWithoutCachePoison`.

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
