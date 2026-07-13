# Hook Schemas

Integration realism: **only listed event types are structurally decoded**.  
Unknown types never crash; they update `Session.rawMetadata` and may set a summary hint.

Wire format for every line: `EventEnvelope` (see `Sources/NocturnalCore/Models/EventEnvelope.swift`).

## Envelope (common)

| Field | Type | Notes |
|-------|------|--------|
| `v` | Int | Schema version; current `1` |
| `id` | UUID string | Unique event id (invalid/missing → generated) |
| `source` | `codex` \| `claude` \| `demo` \| `unknown` | Unknown raw strings decode as `unknown` + optional `sourceRaw` |
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

| Condition | Result |
|-----------|--------|
| `requires_permission` / `requiresPermission` / `needs_permission` == true | `waitingForApproval` |
| `permission` or `permission_mode` string present | `waitingForApproval` |
| Normalized `tool.approval_required` | `waitingForApproval` |
| Otherwise | `running` + tool summary |

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

## Demo / simulation

`source: demo` uses `DemoEventDecoder` (Codex-normalized types + optional `payload.state`).

See `Fixtures/` and `docs/simulation.md`.

`DemoSessions.seedSessions()` prefers `Fixtures/demo/seed-sessions.json` when discoverable, else built-in deterministic seeds.

---

## Fail-open forwarder contract

`nocturnal-hook-forwarder`:

1. Reads stdin (full or line-split; single object without trailing newline is one line)  
2. Optional `--wrap-source codex|claude|demo` runs `EnvelopeNormalizer`  
3. Attempts connect (default 0.5s timeout) + write to socket  
4. **Always exits 0**  
5. Optional debug: `NOCTURNAL_FORWARDER_DEBUG=1`  

Agents must not block on Nocturnal availability.

---

## Response transport (out of band)

User approvals / answers are written under Application Support `responses/`:

| File | Shape |
|------|--------|
| `<request-id>.json` | `ResponseFileEnvelope` (`kind` + `payload`) |
| `codex-<request-id>.json` | Flat Codex-ish decision |
| `claude-<request-id>.json` | Flat Claude-ish permission |
| `answer-<prompt-id>.json` | Flat question answer |

How agents/plugins poll this directory remains an open contract (see `CORE_HANDOFF.md`).
