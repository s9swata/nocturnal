# Hook Schemas

Integration realism: **only listed event types are structurally decoded**.
Unknown types never crash; they update `Session.rawMetadata` and may set a summary hint.

Wire format for every line: `EventEnvelope` (see `Sources/NocturnalCore/Models/EventEnvelope.swift`).

## Envelope (common)

| Field | Type | Notes |
|-------|------|--------|
| `v` | Int | Schema version; current `1` |
| `id` | UUID string | Unique event id (invalid/missing → generated) |
| `source` | `codex` \| `claude` \| `unknown` | Unknown raw strings (including obsolete labels) decode as `unknown` + optional `sourceRaw` |
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

> Real Codex CLI hook configuration formats evolve. The MVP stores a **Nocturnal-managed sidecar** via `nocturnal-setup`. Optional `--mode merge-native` best-effort patches `.codex/hooks.json` (backed up first). Native schema is not vendor-guaranteed.

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

## Simulation

Use Codex and Claude fixtures under `Fixtures/` with the live socket (see `docs/simulation.md`).

---

## Fail-open forwarder contract

`nocturnal-hook-forwarder`:

1. Reads stdin with a **bounded, timeout-aware** reader (size + wall-clock cap; not unbounded `readDataToEndOfFile`)
2. Flags that require values (`--socket`, `--wrap-source`, `--session-id`, `--timeout`) reject a following flag or missing value instead of consuming it as the value (fail-open: ignore bad flag, continue with env/defaults)
3. **Always** normalizes each line through `EnvelopeNormalizer` into a canonical `EventEnvelope` before socket send (optional `--wrap-source` only sets the default source hint). Raw upstream JSON is never sent as-is — `EventSocket` would soft-decode it to `eventType`/`sessionId` defaults
4. Attempts connect (default 0.5s timeout) + write to socket
5. **Always exits 0**
6. Optional debug: `NOCTURNAL_FORWARDER_DEBUG=1`

Agents must not block on Nocturnal availability.

### Setup CLI parse rules

`nocturnal-setup`:

- Omitting `--product` installs for **all** products; omitting `--forwarder` auto-discovers the binary
- Present-but-missing values (`--product` / `--forwarder` with no value, or followed by another flag) are **usage errors** (exit 2) — never silent default to all / auto-discovery
- Generated hook commands **shell-quote** socket and binary paths (Application Support spaces are safe)
- Native merge always **backups** existing config before overwrite (including malformed JSON) and **preserves** string-format Codex hook entries

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
