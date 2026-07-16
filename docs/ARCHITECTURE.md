# Nocturnal Architecture

Nocturnal is a **local-first** macOS 14+ companion for AI coding agents (Codex, Claude Code). It has no accounts, telemetry, cloud backend, paywall, or license gate.

## Goals

- Surface live agent sessions in a quiet menu-bar / floating pill UI
- Receive hook events over a local Unix domain socket (NDJSON)
- Allow approvals / answers without leaving the current focus more than needed
- Jump the user back to Terminal, iTerm2, Ghostty, VS Code, Cursor, or Codex deep links
- Remain fail-open: missing Nocturnal never breaks agent hooks

## Module map

| Target | Kind | Responsibility |
|--------|------|----------------|
| **NocturnalCore** | Library | Models, `SessionStore` actor, socket bridge, decoders, persistence, jump-back, response transport, hook install helpers |
| **Nocturnal** | Executable app | SwiftUI shell (`MenuBarExtra`, Settings, window), `@Observable` `AppModel`, AppKit overlay host |
| **nocturnal-hook-forwarder** | CLI | Fail-open stdin → socket |
| **nocturnal-setup** | CLI | Idempotent native hook install, Doctor, repair, and uninstall |
| **NocturnalCoreTests** | Tests | Swift Testing coverage for core contracts |

```
Codex/Claude native hooks ─► nocturnal-hook-forwarder ─► Unix socket (NDJSON)
                                              │
                                              ▼
                                         EventSocketServer
                                              │
                                              ▼
                                         SessionStore (actor)
                                              │
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                         Persistence     AppModel (@MainActor)  Response files
                         (JSON)          SwiftUI / Overlay

Codex local sessions/session_meta ── bounded read-only catch-up ──► SessionStore
```

## Concurrency boundaries

- **`SessionStore`**: sole owner of mutable session dictionaries; all writes via `apply` / `upsert` / `replaceAll`
- **Models**: pure `Sendable` value types (`Session`, `EventEnvelope`, `AppSettings`, …)
- **UI**: `@MainActor` + `@Observable` (`AppModel`); mirrors store snapshots only
- **Socket server**: `actor EventSocketServer`; yields `AsyncStream<EventEnvelope>`
- **Persistence / settings**: dedicated actors (`SessionPersistence`, `SettingsStore`)
- Prefer structured concurrency; no `Task.detached` without a documented reason

## IPC: NDJSON over Unix domain socket

**Default path:**  
`~/Library/Application Support/Nocturnal/ipc.sock`

**Override:** environment variable `NOCTURNAL_SOCKET` (also used by forwarder and setup).

Each line is one JSON object matching `EventEnvelope` (`v`, `id`, `source`, `eventType`, `sessionId`, `timestamp`, `payload`, `raw`).

See `docs/HOOK_SCHEMAS.md` for which `eventType` values are implemented.

## Persistence layout

```
~/Library/Application Support/Nocturnal/
  ipc.sock
  settings.json
  sessions/<id>.json
  responses/<request-id>.json
  backups/<product>-hooks-<timestamp>.json
```

Override root with `NOCTURNAL_APP_SUPPORT`.  
Config sandbox for setup tests: `NOCTURNAL_CONFIG_ROOT`.

## Hook install model

By default, `nocturnal-setup` merges nested command handlers into the files the
agents actually consume:

- `CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`)
- `~/.claude/settings.json`

It also writes Nocturnal-managed descriptors under:

- `$NOCTURNAL_CONFIG_ROOT/.codex/nocturnal-hooks.json` (default `~/.codex/…`)
- `$NOCTURNAL_CONFIG_ROOT/.claude/nocturnal-hooks.json`

Install is **idempotent**, creates **timestamped backups**, and preserves valid
foreign lifecycle groups/handlers. Codex ownership is recognized by the nested
`nocturnal-hook-forwarder` command because unknown top-level marker fields are
rejected by Codex. `doctor` performs a read-only structural check and reports the
installed Codex version; `repair` migrates the obsolete Nocturnal array schema.

At app bootstrap, a bounded scanner reads only the first `session_meta` line of up
to 100 recent local Codex JSONL files. This creates idle recovery stubs; native
hooks remain authoritative for live state. The scanner never parses prompts,
responses, or tool transcript bodies.

## Response transport

User approvals / answers become JSON under `responses/` (`ResponseFileEnvelope`) **and**, for `PermissionRequest` (decision mode), complete an in-process `PermissionBroker` so the blocked `nocturnal-hook-forwarder` can print Codex/Claude allow/deny JSON on stdout. If Nocturnal is down or the user times out, the forwarder prints `{}` (fail-open → agent’s own prompt).

## Jump-back

`JumpBackCoordinator` tries strategies by priority:

1. Codex deep link  
2. Cursor / VS Code URL schemes  
3. Ghostty / iTerm2 / Terminal.app by bundle id  
4. Reveal cwd in Finder (last resort)

All strategies are fail-soft.

## Empty state & simulation

There is no in-app product demo mode. With zero sessions the UI shows a polished empty state (owl mark, hook setup actions). Exercise live behavior with Codex/Claude NDJSON fixtures over the socket — see `docs/simulation.md` and `Fixtures/{codex,claude}/`.

## Packaging

`Scripts/package_app.sh` builds and assembles:

```
build/Nocturnal.app/
  Contents/MacOS/Nocturnal
  Contents/MacOS/nocturnal-hook-forwarder
  Contents/MacOS/nocturnal-setup
  Contents/Resources/Helpers/…   # same helpers for setup resolution
  Contents/Resources/Fixtures/…
```

`LSUIElement` is enabled (`MENU_BAR_APP=1`) for a companion-style menu bar app.

## What is intentionally not here

- Cloud sync, accounts, analytics, license checks
- Proprietary third-party UI clones
- Claiming unsupported hook event types work (unknown → raw metadata only)
