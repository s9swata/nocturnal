# Review: NocturnalCore (from QA)

- **Reviewer:** nocturnal-qa
- **Date:** 2026-07-13 (updated after follow-up cleanup)
- **Revision / branch:** local workspace after QA follow-up
- **Scope:** decode, store, socket, persistence, hooks, response transport, test seams
- **Note (historical):** Sections below that mention product “demo seeds” / `DemoSessions` are **no longer applicable**. Product demo mode was removed; use Codex/Claude fixtures + socket simulation instead.

## Summary

Core is production-capable for the MVP surface. Public test seams remain real and green under CLT. P0 date-decoder crash was fixed earlier; follow-up closed the socket dual-resolution nit.

**Decision: Approve**

## Findings

### P0 — must fix

- **[FIXED earlier] Recursive `JSONDecoder.dateDecodingStrategy` → SIGBUS**  
  Shared `EventEnvelopeDateParsing.decode(from:)` only decodes `String` / `Double`. Covered by persistence + socket suites.

### P1 — should fix before merge

- **[FIXED this pass] `PersistencePaths.socketURL` vs `NOCTURNAL_SOCKET`**  
  `PersistencePaths.resolve(environment:)` now applies `NOCTURNAL_SOCKET` (or defaults to `{root}/ipc.sock`).  
  `HookInstaller.resolve` and `NocturnalRuntime` consume `paths.socketURL` only.  
  Tests: `resolveHonorsExplicitSocketOverride`, `resolveDefaultsSocketUnderAppSupportRoot`, `testingHelperIgnoresProcessEnvironment`.  
  Short-path helpers: `SocketPaths.makeShortTestingRoot` + existing `/tmp` test roots.

- **Unix socket path length** — still a footgun for deep temp dirs; docs + helpers use short `/tmp` paths. Acceptable with safeguards in place.

### P2 — nice to have

- Native merge formats still lack vendor golden fixtures.
- Jump-back strategies not unit-tested (need injectable openers).
- Forwarder CLI process exit-0 is manual; library path covered.
- Envelope schema “reject / migrate v2” tests not yet present.

### Fixtures / simulation (historical note)

- ~~Product demo question seed / `DemoSessions`~~ — **removed from product**. Exercise `waitingForInput` via Codex/Claude NDJSON fixtures over the live socket (`docs/simulation.md`).

## Coverage map (automated)

| Area | Status | Notes |
|------|--------|-------|
| Codex decode + fixtures | Pass | session start, approval, unknown, question, terminal states |
| Claude decode + PreToolUse matrix | Pass | fixtures + permission true/false + permission_mode |
| Unknown raw metadata | Pass | store + decoder |
| State transitions | Pass | lifecycle + local approve/deny/answer |
| Socket round-trip | Pass | temp short path; multi-line; bad line fail-open |
| Socket path resolution | Pass | env override + default + testing isolation |
| Persistence load/save/corrupt | Pass | quarantine dir asserted |
| Hook install temp-only | Pass | `configRoot` under temp; env resolve → Core socket |
| Response routing | Pass | file + sidecars + multiplex + e2e clear pending |

## Contract checklist

- [x] Builds (`swift build`)
- [x] Tests (`swift test`) — **50** tests via SPM Swift Testing
- [x] Unknown hook events fail soft
- [x] No telemetry / accounts / cloud
- [x] No writes to real `~/.codex` / `~/.claude` in tests
- [x] Sendable / actor boundaries respected in exercised APIs
- [x] Single source of truth for listen socket path in Core
- [x] Handoff doc present (`CORE_HANDOFF.md`)

## Open questions

1. Should corrupt session quarantine paths be surfaced in Settings diagnostics?
2. Reply socket timeline vs file-drop-only for agents?

## Decision

**Approve** — follow-up nits (socket SSoT) landed with tests. Remaining items are P2 / product policy.
