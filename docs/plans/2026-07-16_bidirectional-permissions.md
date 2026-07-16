# Bidirectional permission path — design

**Date:** 2026-07-16  
**Status:** Core shipped; remaining polish / product-specific hardening  
**Goal:** Approving or denying in Nocturnal actually unblocks or blocks Codex (and Claude) instead of only writing local response files.

---

## 1. Shipped core (no longer “future work”)

Implemented in-tree today:

- `PermissionBroker` + `HookDecisionTranslator` + decision-mode socket RPC
- `FailOpenHookForwarder.forwardWithDecision` waits on `PermissionRequest` and prints allow/deny JSON (or `{}` on timeout)
- OpenCode HTTP permission replies via `OpenCodePermissionClient`
- Inline island Deny/Allow for adapters with decision transport

### Historical gap (solved)

| Layer | Was | Now |
|-------|-----|-----|
| Codex `PermissionRequest` | Always `{}` | Decision JSON on stdout when UI answers |
| Nocturnal Approve UI | Response files only | Completes broker + optional HTTP/file transports |
| Timing | Instant exit | Bounded wait (`decisionTimeout`) |

### Still open (focus remaining work here)

- UI copy / always-allow affordances (§5.4)
- Claude-specific translator edge cases
- Enterprise fail-closed settings
- Correlation hardening across product-specific id fields

Official Codex docs ([Hooks](https://learn.chatgpt.com/docs/hooks)):

**PermissionRequest** can **allow**, **deny**, or **decline** (empty / no decision → normal Codex prompt continues).

Allow:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Deny:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Blocked by user via Nocturnal."
    }
  }
}
```

If no matching hook decides, Codex shows its normal approval UI.  
If multiple hooks decide, **any deny wins**; otherwise **allow** skips the prompt.

**PreToolUse** (Codex) can **deny** with:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "…"
  }
}
```

`permissionDecision: "ask"` is **parsed but not supported yet** on PreToolUse (fails hook, tool continues).  
So **user-facing remote approve/deny for Codex is primarily `PermissionRequest`**, not PreToolUse-ask.

Claude Code uses a different shape (`permissionDecision: allow|deny|ask` on PreToolUse / PermissionRequest). Design should support both translators.

---

## 2. Target architecture

```text
Codex PermissionRequest
        │ stdin JSON
        ▼
nocturnal-hook-forwarder  (permission mode)
        │ 1. normalize → EventEnvelope
        │ 2. POST/send to app socket (request needs decision)
        │ 3. WAIT on reply channel (timeout T)
        │
        ├─ Nocturnal running ──► UI shows approval ──► user Allow/Deny
        │                              │
        │                              ▼
        │                         reply to forwarder (allow|deny|timeout)
        │
        └─ Nocturnal down ──► fail-open: print {}  (Codex own prompt)
                                    OR fail-closed deny (optional setting)

forwarder stdout → Codex (decision JSON or {})
forwarder exit 0 always for PermissionRequest path
  (exit 2 + stderr = hard block; avoid unless intentional deny)
```

**Key change:** observer forwarder becomes a **synchronous decision proxy** only for permission-capable events.

---

## 3. IPC contract (Nocturnal ↔ forwarder)

### 3.1 Request (forwarder → app)

Extend NDJSON socket (or add second “control” socket) with a request kind:

```json
{
  "v": 1,
  "kind": "permission.decision_request",
  "id": "<uuid>",
  "source": "codex",
  "sessionId": "…",
  "timestamp": "…",
  "eventType": "PermissionRequest",
  "payload": { /* full hook stdin fields */ },
  "replyDeadlineMs": 120000
}
```

Reuse `EventEnvelope` where possible; add:

| Field | Purpose |
|-------|---------|
| `kind` or `needsDecision: true` | Marks blocking request |
| `decisionRequestId` | Correlates reply |
| `replyPath` or in-band reply | How forwarder receives answer |

**Recommended v1:** Unix socket **request/response on the same connection** (simplest for one hook process):

1. Forwarder connects to `ipc.sock`.
2. Writes one NDJSON line (permission request).
3. Reads one NDJSON line (decision reply) or times out.
4. Maps reply → Codex/Claude stdout JSON.
5. Exits 0.

App side: socket server must support **per-connection RPC** for `permission.decision_request`, not fire-and-forget only.

### 3.2 Reply (app → forwarder)

```json
{
  "v": 1,
  "kind": "permission.decision_reply",
  "decisionRequestId": "<uuid>",
  "behavior": "allow" | "deny" | "defer",
  "message": "optional reason for deny",
  "decidedAt": "ISO-8601"
}
```

| `behavior` | Forwarder stdout |
|------------|------------------|
| `allow` | Codex allow decision JSON |
| `deny` | Codex deny decision JSON |
| `defer` | `{}` — Codex shows its own prompt |
| timeout / app down | configurable: `{}` (fail-open) or deny |

---

## 4. Forwarder modes

### 4.1 Observer (current — keep for lifecycle events)

`SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, …  
→ fire-and-forget to socket, print `{}`, exit 0.

### 4.2 Decision (new — PermissionRequest + optional Claude PreToolUse when `requires_permission`)

```text
--mode decision   # or auto-detect from hook_event_name
--timeout-decision 120   # seconds to wait for UI (default 120)
--on-timeout defer|deny  # default defer (fail-open → Codex prompt)
```

Auto-detect:

```text
if event in {PermissionRequest} → decision mode
else if Claude PreToolUse && requires_permission → decision mode (optional)
else → observer mode
```

### 4.3 Fail-open policy (product)

| Situation | Default | Rationale |
|-----------|---------|-----------|
| Nocturnal not running | `defer` → `{}` | Codex still usable |
| Timeout waiting for user | `defer` → `{}` | Don’t hang forever; Codex can still prompt |
| User Deny in UI | `deny` JSON | Real block |
| User Allow in UI | `allow` JSON | Skip Codex prompt |
| Parse / internal error | `defer` | Fail-open |

Optional setting later: **fail-closed** for enterprise (timeout → deny).

---

## 5. App / SessionStore changes

### 5.1 Pending decision queue

When a decision request arrives:

1. Decode as today → `pendingApproval` + `waitingForApproval`.
2. Register `PendingDecisionWaiter` keyed by `decisionRequestId` / `tool_use_id`.
3. UI shows approval rail (already).
4. On Approve/Deny:
   - Write response files (keep for audit).
   - **Complete waiter** with allow/deny.
   - Clear pending approval as today.

### 5.2 Timeout

App or forwarder owns deadline:

- Prefer **forwarder timeout** (always exits).
- App cancels waiter when connection drops.

### 5.3 Sticky always-allow

If tool ∈ `sessionAlwaysAllowTools`, app can reply **allow immediately** without UI (still log).

### 5.4 UI copy

Change “Recorded approval” → **“Approved in Codex”** only when decision mode succeeded; if observer-only legacy path, keep “Recorded only”.

---

## 6. Claude path (parallel)

Claude PermissionRequest / PreToolUse allow shape (from Claude docs):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

or PreToolUse:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Approved in Nocturnal"
  }
}
```

Forwarder selects translator by `source` / event name.

---

## 7. Hook install changes

`nocturnal-setup` already installs `PermissionRequest`. Ensure:

1. Hook **timeout** ≥ UI wait (e.g. `timeout: 180` seconds in hooks.json).  
   Codex default hook timeout is **600s** if omitted — OK.
2. User **trusts** the hook (`/hooks` in Codex) — document clearly.
3. Matcher `.*` or omit so all tools that need approval hit Nocturnal.

Optional second handler: keep a pure observer for analytics **and** a decision handler — but **deny wins** if both decide; better **one** decision-capable Nocturnal handler.

---

## 8. Implementation plan (phased)

### Phase 0 — Spike (½ day)

1. Manual test: temporary shell wrapper that sleeps 5s then prints allow JSON; register as PermissionRequest hook.  
2. Confirm Codex skips TUI prompt.  
3. Same with deny.  
4. Confirm `{}` still shows Codex prompt.

### Phase 1 — Forwarder decision mode (1–2 days)

1. Detect PermissionRequest (and Claude permission PreToolUse).  
2. Request/response over Unix socket.  
3. Map allow/deny/defer → stdout.  
4. Tests with mock socket (temp path, fake reply).  
5. Default timeout + fail-open defer.

### Phase 2 — Core + UI waiters (1–2 days)

1. `EventSocketServer` supports decision RPC (or dedicated `permission.sock`).  
2. `SessionStore` / `AppModel` pending waiters.  
3. Approve/Deny completes waiter.  
4. Always-allow short-circuit.  
5. Status strings distinguish “decided for agent” vs “recorded only”.

### Phase 3 — Claude + polish (1 day)

1. Claude stdout translator.  
2. Docs: `/hooks` trust, timeout, fail-open.  
3. Simulation: fixture permission + mock decision.  
4. UI: timeout progress (“Waiting for you · 1:42”).

### Phase 4 — Hardening (optional)

1. Fail-closed setting.  
2. Multi-request queue UI.  
3. Correlation by `tool_use_id` if present.  
4. Metrics: decision latency, timeout rate.

---

## 9. Risks & product constraints

| Risk | Mitigation |
|------|------------|
| Hanging Codex forever | Hard timeout; default defer |
| Breaking fail-open | Observer events unchanged; decision path defaults defer on error |
| Double prompts (Nocturnal + Codex) | Allow must be returned **before** Codex shows UI; if defer, only Codex prompts |
| Hook not trusted | Doc + Settings copy; setup doctor checks |
| Concurrent PermissionRequests | Queue waiters by id; UI lists all pending |
| PreToolUse “ask” unsupported on Codex | Use PermissionRequest only for interactive approve |
| Security | Local socket only; no network; decision only after explicit UI action |

---

## 10. File touch list (minimum)

| Area | Files |
|------|--------|
| Forwarder | `Sources/nocturnal-hook-forwarder/main.swift`, `HookForwarderProtocol.swift` |
| Socket | `EventSocket.swift` — request/response framing |
| Store | `SessionStore.swift` — waiter registry or actor `PermissionBroker` |
| App | `AppModel.approve` — complete waiter |
| Setup | `HookInstaller.swift` — timeout, docs |
| Tests | Decision mode unit tests with mock peer |
| Docs | `HOOK_SCHEMAS.md`, `ARCHITECTURE.md`, this plan |

---

## 11. Success criteria

- [ ] User Allow in Nocturnal → Codex proceeds **without** terminal y/N for that PermissionRequest.  
- [ ] User Deny → Codex tool blocked with Nocturnal message.  
- [ ] Nocturnal quit mid-wait → Codex falls back to its own prompt (defer).  
- [ ] Lifecycle hooks still fail-open and never block.  
- [ ] `swift test` green; no writes to real `~/.codex` in tests.

---

## 12. Recommendation

**Implement Phase 0 spike first** (static allow script) to prove Codex version on your machine honors PermissionRequest stdout.  
Then **Phase 1–2** — the real product path is **blocking forwarder + socket reply**, not watching `responses/*.json` (Codex never reads those).

File-based responses remain useful as **audit log**, not as the control plane.

---

*End of design.*
