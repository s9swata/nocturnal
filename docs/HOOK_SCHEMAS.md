# Hook Schemas

Integration realism: **only listed event types are structurally decoded**.
Unknown types never crash; they update `Session.rawMetadata` and may set a summary hint.

Wire format for every line: `EventEnvelope` (see `Sources/NocturnalCore/Models/EventEnvelope.swift`).

## Envelope (common)

| Field | Type | Notes |
|-------|------|--------|
| `v` | Int | Schema version; current `1` |
| `id` | UUID string | Unique event id (invalid/missing → generated) |
| `source` | `codex` \| `claude` \| `opencode` \| `grok-build` \| `cursor` \| `kimi` \| `agy` \| `unknown` | Unknown raw strings decode as `unknown` + optional `sourceRaw` |
| `eventType` | String | Upstream or normalized name |
| `sessionId` | String | Groups events into one `Session` |
| `timestamp` | ISO-8601 | Fractional seconds accepted |
| `payload` | object | Known fields when available |
| `raw` | object | Full upstream object / extras |
| `sourceRaw` | string? | When source is unknown |

Resilient decode: bad dates/ids never crash the socket server; bad lines are dropped and counted in `EventSocketDiagnostics`.

---

## Codex — implemented

Decoder: `CodexEventDecoder`
Set: `CodexEventDecoder.implementedEventTypes`

| eventType | Normalized state | Notes |
|-----------|------------------|--------|
| `session.started` | `running` | title, cwd |
| `session.updated` | `running` | summary refresh |
| `session.completed` | `completed` | |
| `session.failed` | `failed` | |
| `session.cancelled` | `cancelled` | |
| `agent.turn.started` | `running` | |
| `agent.turn.completed` | `idle` | |
| `tool.approval_required` | `waitingForApproval` | builds `ApprovalRequest` |
| `tool.approval_resolved` | `running` | clears pending approval |
| `agent.question` | `waitingForInput` | builds `QuestionPrompt` |
| `agent.question_answered` | `running` | clears pending question |
| `SessionStart` | `running` | Native Codex 0.144.1 lifecycle hook |
| `UserPromptSubmit` | `running` | Native lifecycle hook |
| `PreToolUse` / `PostToolUse` | `running` | Native lifecycle hook |
| `PermissionRequest` | `waitingForApproval` | **Bidirectional:** forwarder waits for Nocturnal Allow/Deny, then prints Codex decision JSON on stdout (or `{}` if app down / timeout → Codex own prompt) |
| `Stop` | `idle` | Native lifecycle hook |
| `SubagentStart` / `SubagentStop` | `running` | Decoded if received; not installed by default |
| `PreCompact` / `PostCompact` | `running` | Decoded if received; not installed by default |
| `session.reconciled` | `idle` | Local `session_meta` catch-up; never claims live state |

### Codex payload fields (best-effort)

| Field | Used for |
|-------|----------|
| `title`, `session_title`, `name` | Session title |
| `summary`, `message`, `status_text` | Summary line |
| `cwd`, `working_directory`, `workdir`, `workspace_root` | Working directory / jump-back |
| `request_id`, `id`, `approval_id` | Approval / prompt id |
| `tool`, `tool_name`, `name` | Approval tool name |
| `detail`, `description`, `command`, `input` | Approval detail |
| `risk`, `risk_hint` | `low` / `medium` / `high` |
| `prompt`, `question`, `text` | Question text |
| `choices` | Optional choice list |
| `allow_freeform` | Bool |
| `codex_url`, `deep_link`, `deeplink` | Jump-back deep link |
| `terminal_bundle_id`, `terminal_tab_title` | Jump-back terminal focus |
| `editor_url` | Jump-back editor URL |
| `pid`, `process_id` | Optional process hint |

### Codex — not implemented (examples)

Any other `eventType` (streaming tokens, file diffs, MCP internals, future experimental hooks) is **unknown**:

- `isUnknown == true`
- raw preserved
- state left unchanged unless session is new (defaults to `idle`)

### Codex native hook configuration

The adapter is verified against Codex CLI 0.144.1. Codex consumes an event-keyed
map, not Nocturnal's obsolete array shape:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": ".../nocturnal-hook-forwarder --wrap-source codex"
      }]
    }]
  }
}
```

Only `description` and `hooks` are written at the top level. Install merges one
Nocturnal handler into each of `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PermissionRequest`, `PostToolUse`, and `Stop`; foreign handlers remain intact.
The descriptor `nocturnal-hooks.json` is not consumed by Codex.

`nocturnal-setup doctor --product codex` checks the structure and reports the
Codex CLI version. `repair` migrates the obsolete Nocturnal array after creating a
backup. Malformed/ambiguous foreign configuration is backed up and refused rather
than silently overwritten.

---

## Claude Code — implemented

Decoder: `ClaudeEventDecoder`
Set: `ClaudeEventDecoder.implementedEventTypes`

| eventType | Normalized state | Notes |
|-----------|------------------|--------|
| `SessionStart` | `running` | |
| `SessionEnd` | `completed` | |
| `UserPromptSubmit` | `running` | informational |
| `PreToolUse` | `running` or `waitingForApproval` | Approval only if permission fields (see matrix) |
| `PostToolUse` | `running` | |
| `Notification` | _(unchanged)_ | summary only |
| `Stop` | `idle` | |
| `SubagentStop` | `idle` | |
| Normalized aliases | same as Codex rows | Used by fixtures / simulator |

### PreToolUse permission matrix

Permission / mode strings use a **semantic allowlist**, not mere presence.

| Condition | Result |
|-----------|--------|
| `requires_permission` / `requiresPermission` / `needs_permission` == true | `waitingForApproval` |
| `requires_permission` / … == false (explicit) | `running` (wins over mode string) |
| `permission_mode` / `permission` ∈ `{ask, default, prompt}` | `waitingForApproval` |
| `permission_mode` / `permission` ∈ `{none, off, allow, bypassPermissions, dontAsk, acceptEdits, …}` | `running` (no false approval) |
| Unknown mode string | `running` (fail-open; no invented gate) |
| Normalized `tool.approval_required` | `waitingForApproval` |
| Otherwise | `running` + tool summary |

Source of truth sets: `ClaudeEventDecoder.permissionModesRequiringApproval` and
`ClaudeEventDecoder.permissionModesAutoAllow`.

### Claude raw stdin normalization

`EnvelopeNormalizer` (and `nocturnal-hook-forwarder --wrap-source claude`) maps common Claude hook fields into `EventEnvelope`:

| Upstream field | Envelope field |
|----------------|----------------|
| `hook_event_name` / `hookEventName` | `eventType` |
| `session_id` / `sessionId` | `sessionId` |
| full object | `payload` + `raw` |

Until vendor shapes stabilize, treat this as best-effort. Unknown objects still land in `raw` with a careful `eventType` default (`raw.unparsed` only when JSON parse fails).

### Claude — not implemented (examples)

- Permission modes not expressed as PreToolUse + permission flags
- Any event type outside the set above

---

## OpenCode — implemented (Phase 1, observe-only)

OpenCode does **not** use Codex/Claude shell hooks. Integration is a managed JS
plugin written by `nocturnal-setup`:

| Path | Role |
|------|------|
| `~/.config/opencode/plugins/nocturnal-bridge.js` | Auto-loaded plugin; maps events → `EventEnvelope` NDJSON on `NOCTURNAL_SOCKET` / installed socket path |
| `~/.config/opencode/nocturnal-hooks.json` | Nocturnal-owned sidecar descriptor (not consumed by OpenCode) |

Decoder: `OpenCodeEventDecoder`  
Set: `OpenCodeEventDecoder.implementedEventTypes`

### Strategy A (preferred wire shape)

The plugin emits **Codex-shaped** lifecycle names with `source: "opencode"` so
`SessionActivityMapping` works unchanged:

| OpenCode origin | Emitted `eventType` | State |
|-----------------|---------------------|--------|
| `session.created` | `SessionStart` | `running` |
| `session.updated` / `session.status` | `session.updated` | `running` |
| `session.idle` | `Stop` | `idle` |
| `session.error` | `session.failed` | `failed` |
| `session.deleted` | `session.completed` | `completed` |
| `tool.execute.before` | `PreToolUse` | `running` |
| `tool.execute.after` | `PostToolUse` | `running` |
| `permission.asked` | `PermissionRequest` | `waitingForApproval` (observe only) |
| `permission.replied` | `tool.approval_resolved` | `running` |
| `file.edited` | `PostToolUse` | `running` |

The decoder also accepts the **native** OpenCode names above and normalizes them.

### Payload fields (best-effort)

| Field | Used for |
|-------|----------|
| `tool` / `tool_name` | Tool activity label |
| `args` / `tool_input` | OpenCode tool arguments (`command`, `filePath`, …) |
| `command` | Shell detail |
| `file_path` / `filePath` | Read/edit path |
| `cwd` / `working_directory` | Session cwd (plugin injects OpenCode `directory`) |
| `title` | Session title |
| `request_id` / `id` | Permission correlation (Phase 1 display only) |

### Fail-open

The plugin never throws into OpenCode tool execution. Connect/write failures are
ignored (short connect timeout ~350ms). If Nocturnal is down, OpenCode continues.

### Phase 2 — Bidirectional permissions (plugin v3)

1. **`permission.ask` plugin hook** (primary) receives the permission object and can set
   `output.status = "allow" | "deny" | "ask"` before OpenCode’s TUI owns it
2. Emits `PermissionRequest` with `nocturnalNeedsDecision` + permission id + `opencode_server_url`
3. Waits on the socket until Nocturnal Allow/Deny (or 120s timeout)
4. On allow/deny:
   - sets `output.status`
   - calls SDK `postSessionIdPermissionsPermissionId` and/or  
     `POST {serverUrl}/session/{id}/permissions/{permissionID}`  
     body: `{ "response": "once" | "always" | "reject" }`
5. Bus event `permission.asked` is a de-duped fallback
6. Timeout / Nocturnal down → leave `ask` (OpenCode TUI) — fail-open

Debug log (plugin): `/tmp/nocturnal-opencode-bridge.log`

**Note:** OpenCode defaults most tools to `allow`. Use project `opencode.json`:

```json
{ "permission": { "bash": "ask", "edit": "ask", "external_directory": "ask" } }
```

If global config has **two** `"permission"` keys, the last one wins — keep a single object.

### Identity (anti-Claude mislabel)

OpenCode session ids are `ses_*` and new chats are often titled
`New session - <ISO-8601>`. Lifecycle events are mapped to Claude/Codex names
(`SessionStart`, `PreToolUse`, …), so missing wire `source` used to be inferred
as **Claude**.

Nocturnal now:

1. Forces `source: opencode` for `ses_*` ids / OpenCode title patterns
2. Repairs mislabeled rows on hydrate + apply
3. Soft-idles OpenCode “start shells” stuck in `running` with no tools after 90s

### Phase 3 — Offline recovery

`OpenCodeSessionScanner` reads (read-only, bounded):

| Source | Path |
|--------|------|
| SQLite (preferred) | `~/.local/share/opencode/opencode.db` table `session` |
| JSON fallback | `~/.local/share/opencode/storage/session/<project>/<id>.json` |

Emits `session.reconciled` with title, cwd, tokens, and diff summary when present.
Never claims live running state.

Tests use `NOCTURNAL_CONFIG_ROOT` → `<root>/.local/share/opencode`.

### Setup

```bash
nocturnal-setup install --product opencode
nocturnal-setup doctor --product opencode
```

Requires a running Nocturnal app (socket listener). Restart OpenCode after install
so it loads the plugin.

---

## Simulation

Use Codex, Claude, and OpenCode fixtures under `Fixtures/` with the live socket (see `docs/simulation.md`).

---

## Fail-open forwarder contract

`nocturnal-hook-forwarder`:

1. Reads stdin with a **bounded, timeout-aware** reader (size + wall-clock cap; not unbounded `readDataToEndOfFile`)
2. Flags that require values (`--socket`, `--wrap-source`, `--session-id`, `--timeout`) reject a following flag or missing value instead of consuming it as the value (fail-open: ignore bad flag, continue with env/defaults)
3. **Always** normalizes each line through `EnvelopeNormalizer` into a canonical `EventEnvelope` before socket send (optional `--wrap-source` only sets the default source hint). Raw upstream JSON is never sent as-is — `EventSocket` would soft-decode it to `eventType`/`sessionId` defaults
4. Attempts connect (default 0.5s timeout) + write to socket
5. **Always exits 0**
6. Prints `{}` so Codex hooks that parse stdout receive an empty success response
7. Optional debug: `NOCTURNAL_FORWARDER_DEBUG=1`

Agents must not block on Nocturnal availability.

### Setup CLI parse rules

`nocturnal-setup`:

- Omitting `--product` installs for **all** products; omitting `--forwarder` auto-discovers the binary
- Present-but-missing values (`--product` / `--forwarder` with no value, or followed by another flag) are **usage errors** (exit 2) — never silent default to all / auto-discovery
- Generated hook commands **shell-quote** socket and binary paths (Application Support spaces are safe)
- Native merge is the default; `--mode sidecar` is descriptor-only
- Native merge always **backs up** existing config before overwrite and preserves valid foreign lifecycle handlers
- `doctor` is read-only; `repair` only replaces Nocturnal-owned nested handlers

---

## Response transport (out of band)

User approvals / answers are written under Application Support `responses/`.
Filenames use collision-free ``PathComponentEncoding`` under a disjoint `records/`
subdirectory (case-stable percent-encode; prior flat / `n.` / underscore layouts are read-only migration candidates).

| File | Shape |
|------|--------|
| `<encoded-request-id>.json` | `ResponseFileEnvelope` (`kind` + `payload`) |
| `codex/<encoded-request-id>.json` | Flat Codex-ish decision sidecar |
| `claude/<encoded-request-id>.json` | Flat Claude-ish permission sidecar |
| `answer/<encoded-prompt-id>.json` | Flat question answer sidecar |

Sidecars live in **subdirectories** so envelope id `codex-x` never collides with
the Codex sidecar for id `x`. Legacy flat `codex-<id>.json` names are not written.

How agents/plugins poll this directory remains an open contract (see `CORE_HANDOFF.md`).
