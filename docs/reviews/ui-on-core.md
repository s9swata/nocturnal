# Review: NocturnalCore (from UI)

- **Reviewer:** nocturnal-ui
- **Date:** 2026-07-13
- **Revision / branch:** local workspace after UI MVP
- **Scope:** public APIs used by `AppModel` — store, socket, settings, transport, jump-back, paths
- **Note (historical):** Mentions of product demo seeds / `DemoSessions` below are **no longer applicable**. Demo mode was removed; simulate via fixtures + socket.

## Summary

Core is shippable for the UI MVP. Snapshot streaming, local response apply, and jump-back coordinator plug in cleanly without the UI needing to own session mutation. A few path/contract nits forced thin workarounds in `AppModel`; none block the shell.

**Decision: Approve with nits**

## Findings

### P0 — must fix

- None for UI integration. `swift build` green with full shell wired.

### P1 — should fix before merge

- **`PersistencePaths.socketURL` ignores `NOCTURNAL_SOCKET`**  
  Production docs and the forwarder use `SocketPaths` / `NOCTURNAL_SOCKET`, but `PersistencePaths.resolve()` always sets `socketURL` to `{appSupport}/ipc.sock`. UI resolves the env override locally before `EventSocketServer.start`. Prefer a single source of truth (e.g. `PersistencePaths` consults `NOCTURNAL_SOCKET`, or document that hosts must call `SocketPaths.resolve()` for listen path).

- **`CORE_HANDOFF` bootstrap vs `SettingsStore.load()`**  
  Handoff shows `try await settingsStore.load()` which is correct from outside the actor, but the method is a synchronous `throws` on the actor (not `async throws`). Harmless; consider aligning the sample or making load explicitly `async` for future IO.

### P2 — nice to have

- **Attention ordering is UI-side**  
  `SessionStoreSnapshot.sessionsNeedingAttention` filters but the main `sessions` array is recency-ordered. UI re-sorts for display. Optional: `orderedForUI` helper on the snapshot to keep sort policy in one place.

- ~~**Demo seed without pending question**~~ — **historical / no longer applicable.** Product demo removed; use Codex/Claude fixtures for question-sheet QA.

- **Jump-back result copy**  
  `JumpBackResult.detail` is good status-line material. No structured error enum — fine for MVP.

- **Response transport success is opaque**  
  `submit` + `applyLocalResponse` is the right split. UI cannot know if an agent ever consumed the file; status says “Approved” meaning “recorded locally,” which is honest enough.

- **Metrics surface**  
  `unknownEventCount` is on the snapshot but not yet shown in Settings. Low priority.

### Contract checklist

- [x] Builds (`swift build`)
- [ ] Tests (`swift test`) — CLT-only host lacks XCTest/Testing (known)
- [x] Unknown hook events fail soft (UI does not special-case; store preserves)
- [x] No telemetry / accounts / cloud
- [x] No writes to real `~/.codex` / `~/.claude` from UI
- [x] Sendable / actor boundaries respected (UI façade on `@MainActor`, store mutations via actor)
- [x] Handoff doc available (`CORE_HANDOFF.md`)

## What worked well

1. **`SessionStore.snapshots()`** — current snapshot first; simple observe loop for SwiftUI.
2. **`applyLocalResponse`** — clears pending approval/question without the UI editing maps.
3. **`AppSettings`** — reduce motion, sound, pill, max visible cover the shell (obsolete `demoMode` key ignored on decode).
4. **`JumpBackCoordinator`** — fail-soft detail string is ideal for a quiet status line.
5. **Types are `Sendable` value models** — easy to pass into sheets and rows.

## Open questions

1. Should packaged app set `LSUIElement` and drop the main `Window` scene, or keep the window for support diagnostics?
2. Will agents grow a reply socket, or remain file-drop only? UI assumes file transport only.
3. Confirm Codex deep-link scheme so Jump back from live sessions is reliable.

## Decision

**Approve with nits** — Core is ready for the UI shell. Address socket-path single-source-of-truth when convenient; exercise answer sheet via Codex/Claude fixtures (not product demo).
