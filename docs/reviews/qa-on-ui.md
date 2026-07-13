# Review: Nocturnal UI shell (from QA)

- **Reviewer:** nocturnal-qa
- **Date:** 2026-07-13 (updated after follow-up cleanup)
- **Revision / branch:** local workspace after QA follow-up
- **Scope:** `Sources/Nocturnal/**`, packaging as menu-bar companion, handoff claims

## Summary

UI shell builds, packages as `LSUIElement` companion, and keeps session mutation inside `SessionStore` via `AppModel`. No automated UI tests (CLT has no XCTest UI runner). Follow-up removed AppModel’s duplicate socket env parsing and clarified response status copy.

**Decision: Approve**

## Findings

### P0 — must fix

- None. `swift build` + `Scripts/package_app.sh` produce signed `build/Nocturnal.app`.

### P1 — should fix before merge

- **[FIXED this pass] Socket path dual-resolution**  
  `AppModel` now uses `PersistencePaths.resolve().socketURL` only (no private `resolvedSocketURL` / env re-parse). Settings path display and live listen path share Core resolution.

- **No automated UI regression suite** — still true; approve/answer/reduce-motion remain manual. Acceptable for MVP.

### P2 — nice to have

- ~~**Demo `waitingForInput` session**~~ — **historical / no longer applicable.** Product demo removed; use fixtures + socket.
- **[FIXED this pass] Status copy honesty** — UI now reports “Recorded approval”, “Recorded denial”, “Recorded answer” (local file-drop), not “agent consumed”.
- Main `Window` always registered — fine for `swift run`; packaged LSUIElement hides Dock.
- Non-activating panel keyboard focus — known limit; not a ship blocker.

### Packaging cleanup

- Removed obsolete `Sources/Nocturnal/Resources/placeholder.txt` and SPM `resources:` entry.
- Packaged app resources: `Fixtures/` + `Helpers/` only (no placeholder, no empty SPM bundle after clean build).

## Packaging verification (post follow-up)

| Check | Result |
|-------|--------|
| `Scripts/package_app.sh` | exit 0 → `build/Nocturnal.app` |
| `file` main binary | Mach-O 64-bit executable arm64 |
| Helpers present | `Contents/Resources/Helpers/{nocturnal-hook-forwarder,nocturnal-setup}` |
| Fixtures bundled | `Resources/Fixtures/{codex,claude}` |
| Placeholder | **absent** |
| `LSUIElement` | `true` (`MENU_BAR_APP=1` default) |
| `codesign -dv` | adhoc signature on app + helpers |
| Sealed Resources | files=10 |
| Version | `CFBundleShortVersionString=0.1.0`, `CFBundleVersion=1` |

## Architecture / brand

- Design tokens follow quiet nocturnal palette (no neon / glass island chrome observed).
- `@Observable` façade only; `approve` / `answer` go through `ResponseTransporting` + `store.applyLocalResponse`.
- Status messages no longer imply external agent consumption of responses.

## Contract checklist

- [x] Builds (`swift build`)
- [x] Tests for core still green with UI present (**50** tests)
- [x] Unknown hooks not claimed in UI copy
- [x] Response success copy is local-record accurate
- [x] No telemetry / accounts / cloud
- [x] No real agent-config writes from UI code
- [x] Actor boundaries: UI does not mutate session maps
- [x] Socket path owned by Core
- [x] Handoff doc present (`UI_HANDOFF.md`)

## Gaps (remaining)

| Gap | Owner suggestion |
|-----|------------------|
| VoiceOver pass on overlay expand | ui + human QA |
| Hide main window when packaged agent-only | ui / packaging |
| Automated UI regression | ui + tooling (needs Xcode UI tests or manual checklist) |

## Decision

**Approve** — UI MVP ready for local dogfood and simulation. Follow-up nits closed.
