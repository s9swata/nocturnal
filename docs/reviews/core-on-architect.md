# Review: architect scaffold (from core)

- **Reviewer:** nocturnal-core
- **Date:** 2026-07-13
- **Revision / branch:** local workspace after core MVP
- **Scope:** package layout, public type contracts, IPC/persistence/hooks seams, docs

## Summary

Architect scaffold was solid and buildable. Core productionized the skeletons without renaming public types. A few contract gaps were closed in-place; remaining open contracts are documented in `CORE_HANDOFF.md` and `docs/HOOK_SCHEMAS.md`.

**Decision: Approve with nits** (nits fixed or documented).

## Findings

### P0 — must fix

- None blocking ship of the scaffold itself.

### P1 — should fix before merge (addressed by core)

- **`AgentSource` / `EventEnvelope` decode fragility** — strict enum decode would drop lines with unknown `source` or odd dates/ids. Core made decode resilient (unknown source, generated ids, tolerant ISO-8601).
- **`EventSocketServer` accept cancel** — blocked `accept` ignored `stop()`. Core closes the listening fd and tracks client tasks; client connect uses non-blocking + poll timeout.
- **Session growth** — no cap/prune/hydrate. Core added `SessionStorePolicy`, prune, disk hydrate, optional auto-persist.
- **Hook install only sidecar** — architect left native merge open. Core kept sidecar default and added opt-in `--mode merge-native` with backups + dry-run (honest, best-effort).
- **Forwarder no wrap path** — raw Claude stdin would not match envelope. Core added `EnvelopeNormalizer` + `--wrap-source`.
- **Demo vs disk** — attaching persistence before demo load could write synthetic sessions. Core disables auto-persist in demo mode via `AppModel`.

### P2 — nice to have

- **Swift Testing under CLT** — handoff claimed XCTest works under CLT; on this machine neither `XCTest` nor `Testing` links without full Xcode. QA should run tests under Xcode; core left XCTest suite intact.
- **Jump-back AppleScript** — tab matching is best-effort; Ghostty has no tab API (activate only). Acceptable for MVP.
- **`CompositeEventDecoder` as class** — became a class for metrics locking; still `EventDecoding` / `@unchecked Sendable`. Prefer actor metrics later if contention matters (it does not).
- **Response reply socket** — still file-only; multiplex transport ready for a second backend.

## Contract checklist

- [x] Builds (`swift build`)
- [ ] Tests (`swift test`) — blocked by missing XCTest/Testing on CLT-only host
- [x] Unknown hook events fail soft
- [x] No telemetry / accounts / cloud
- [x] No writes to real `~/.codex` / `~/.claude` in verification (used `NOCTURNAL_CONFIG_ROOT`)
- [x] Sendable / actor boundaries respected
- [x] Handoff doc updated (`CORE_HANDOFF.md`)

## Open questions

1. Confirm production Codex deep-link URL scheme with a live Codex install.
2. Confirm Claude `settings.json` hooks shape against a current Claude Code release.
3. Who consumes `responses/*.json` — a first-party plugin, or agent-side poll?

## Decision

**Approve with nits** — scaffold contracts were good; core closed the production gaps above without breaking the public type names UI already depends on.
