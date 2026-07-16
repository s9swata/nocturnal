# AGENTS.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


## Product constraints

- **Local-first** macOS 14+ companion for Codex / Claude Code
- **No** accounts, trials, licenses, paywalls, telemetry, or cloud backends
- **Fail-open** hooks: agent must never break if Nocturnal is down
- **No** proprietary cloning of other agents’ UI (including “Vibe Island”-style chrome)
- Quiet nocturnal brand — see `.impeccable.md`

## Roles

| Agent | Owns | Handoff |
|-------|------|---------|
| **nocturnal-architect** | Package layout, contracts, docs, packaging scaffold | `ARCHITECT_HANDOFF.md` |
| **nocturnal-core** | `NocturnalCore`, forwarder, setup CLI, persistence, decoding | `CORE_HANDOFF.md` |
| **nocturnal-ui** | SwiftUI/AppKit shell, pill, panel, settings, a11y | `UI_HANDOFF.md` |
| **nocturnal-qa** | Tests, fixtures, simulation verification | notes under `docs/reviews/` |

## Toolchain

- Swift **6.2.x** / SwiftPM (`// swift-tools-version: 6.2`)
- macOS 14+ deployment target
- Command Line Tools sufficient for `swift build` (full Xcode optional)
- Swift Testing for unit tests (`NocturnalCoreTests`)

## Commands

```bash
swift build
swift test
swift run Nocturnal
swift run nocturnal-hook-forwarder --help
swift run nocturnal-setup --help
Scripts/package_app.sh          # → build/Nocturnal.app
```

## Layout

```
Package.swift
Sources/NocturnalCore/     # library
Sources/Nocturnal/         # app
Sources/nocturnal-hook-forwarder/
Sources/nocturnal-setup/
Tests/NocturnalCoreTests/
Fixtures/
Scripts/package_app.sh
docs/
```

## Rules of engagement

1. Prefer completing the assigned module thoroughly over stubs.
2. Unknown hook events → preserve raw metadata; do not pretend support.
3. Tests must use temp dirs / `NOCTURNAL_CONFIG_ROOT` — **never** write real `~/.codex` or `~/.claude`.
4. Respect actor boundaries: UI does not mutate session maps; store is the source of truth.
5. Do not commit unless the user asks.
6. Peer reviews go in `docs/reviews/` (see that README for format).

## Key docs

- `docs/ARCHITECTURE.md` — system design
- `docs/AGENT_INTEGRATION.md` — multi-agent model (NAP, profiles, tiers A–C)
- `docs/HOOK_SCHEMAS.md` — implemented vs unknown events
- `docs/simulation.md` — local simulation recipes
- `ARCHITECT_HANDOFF.md` — next implementation tasks
- `.impeccable.md` — design context
