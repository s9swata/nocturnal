# AGENTS.md — Nocturnal

Guidance for humans and coding agents working in this repository.

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
- `docs/HOOK_SCHEMAS.md` — implemented vs unknown events
- `docs/simulation.md` — local simulation recipes
- `ARCHITECT_HANDOFF.md` — next implementation tasks
- `.impeccable.md` — design context
