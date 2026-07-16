# Notch feature expansion — implementation plan (MVP hour)

**Date:** 2026-07-16  
**Audience:** `nocturnal-core` → `nocturnal-ui` (then tests)  
**Window:** ~1 hour autonomous MVP slice — visible competitive value, not a third-party clone  
**Brand:** Nocturnal monochrome owl (`.impeccable.md`); notch-hug OK; **no** glass/neon “Vibe Island” chrome  

---

## 1. Goals / non-goals

### Goals (this build window)

Ship a **noticeable density upgrade** on the existing notch stack:

1. **Pill:** activity **verb** (semantic color by kind) + truncated detail — still black top-flat drip.
2. **Rows:** richer meta line — **duration**, **tool-use count**, **source chip**, **jump-back surface badge** (when known).
3. **Header:** session count + compact toolbar (settings / folders / collapse) — **no fake usage meters**.
4. **Approvals:** full-width **PERMISSION** banner, monospaced detail preview, **Allow / Deny / Deny with note**; optional **Always allow this tool (session)** as a **local sticky + best-effort sidecar flag** (never claim agent honored it).
5. **Questions:** choice list as exclusive radios (or multi only if payload clearly multi) + freeform **Other…** + Send — still one `QuestionPrompt` at a time.
6. **Detail / timeline:** expand selected row (or inline section) showing **recentActivities** as a tool timeline with durations.
7. **Folders:** reveal grid for local roots (Nocturnal App Support, Claude/Codex config/logs when present) — Finder only.

### Non-goals

- Cloning proprietary glass/neon island UI or competitive marketing chrome.
- Accounts, telemetry, cloud usage APIs, paywalls.
- Real **5H/7D quota** meters, **token up/down**, **diff +/−**, **full last-reply transcripts**, **localhost port scanning**.
- Inventing hook support for unknown event types.
- Mutating session maps from UI (`SessionStore` remains source of truth).
- Breaking fail-open forwarder / exit-0 contract.

### Data reality (gates design)

| Competitive UI | Hook/data truth today |
|----------------|----------------------|
| Live verb / tool line | **Yes** — `Session.currentActivity` / `recentActivities` via Pre/PostToolUse + lifecycle |
| Duration | **Yes** — `createdAt`/`updatedAt`, activity `startedAt`/`endedAt` |
| Tool counts | **Partial** — count tool activities; optional path set if `file_path` present |
| Token / diff / quotas | **No** — omit or never fake numbers |
| Last reply body | **No** — optional collapsible “Last activity” from activity/summary only |
| Multi-section forms | **Partial** — single `QuestionPrompt` + `choices[]` + freeform |
| Always Allow | **Local only** unless agent later reads sidecar `permission` / `scope` |
| Local servers | **No process scan in this hour** |

---

## 2. P0 feature list + acceptance criteria

### P0-A — Activity verb + pill density

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-A1 | Pill shows **verb** (from activity kind/label) with **semantic color**, detail in primary/secondary | Given PreToolUse `shell` + command, pill ≈ `shell · npm test` (or detail-first); verb uses palette rule (tool=fgSecondary/success pulse, approval=accentAttention). **No neon cyan.** |
| P0-A2 | `SessionPresentation.liveActivityLine` prefers short verb + detail | Unit-testable pure helper still drives pill; attention still wins. |
| P0-A3 | Compact geometry unchanged enough for notch hug | Still uses `OverlayGeometry` compact ~272×38; top-flat shape; no rectangular chrome. |

### P0-B — Session stats (hook-derived only)

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-B1 | `Session` gains bounded **stats** updated only in store | After N PreToolUse tools, `session.stats.toolUseCount == N` (or Post-only increments once — pick one rule and test it). |
| P0-B2 | Optional file touch count when path fields present | If payload has `file_path` / `path` / tool_input path, `filesTouchedCount` increments unique (cap tracked set). Missing path → no fake file count. |
| P0-B3 | Row meta shows duration + tool count when non-zero | e.g. `12m · 4 tools` or `· 2 files`; never show `+754 -158` or tokens. |
| P0-B4 | Codable backward compatible | Old session JSON without `stats` loads with zeros. |

### P0-C — Panel header toolbar

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-C1 | Header: owl + “Sessions” + **count** + attention badge | Count matches visible or total sessions (document which: **total in snapshot**). |
| P0-C2 | Buttons: **Folders** (sheet/popover), **Settings** (`openSettings`), collapse | Settings opens system Settings scene; folders does not crash if path missing. |
| P0-C3 | **No** Claude/Codex 5H/7D meters | Do not stub percentages. Optional future P2 empty slot not shown. |

### P0-D — Permission UX upgrade

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-D1 | When selected/attention session has `pendingApproval`, panel shows **banner** + monospaced detail (not only tiny sheet) | Overlay expanded + approval fixture: user sees “Permission requested”, tool name, detail scroll. |
| P0-D2 | Actions: **Deny**, **Allow**, **Deny with note…** | Allow/Deny write `ApprovalDecision` via transport + `applyLocalResponse`; note path fills `decision.note`. |
| P0-D3 | Shortcuts: Prefer **⌘↩ / Return = Allow**, **⌘D or D = Deny** (keep existing overlay A/D); document any change | Existing a11y actions still work. |
| P0-D4 | **Always allow (this session)** | Toggles local session sticky for `toolName`; next identical tool approval may auto-approve **only inside Nocturnal** and write allow decision; status must say **“Recorded approval (local always-allow)”** — never “agent accepted”. |
| P0-D5 | Post-decision: summary/activity “Approved” / “Denied” already exists; optional brief success strip in panel | No confetti; monochrome success text. |

### P0-E — Question sheet polish

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-E1 | Choices as selectable list (radio semantics when single-answer) | Selecting a choice fills answer; Send still required unless product chooses tap-to-send for choices only — **prefer explicit Send** for fewer mis-clicks. |
| P0-E2 | “Other…” reveals freeform when `allowFreeform` | Matches existing model; empty send blocked. |
| P0-E3 | No multi-question progress (“1 of 2”) unless we invent state | Skip progress chrome in P0. |

### P0-F — Timeline (selected session)

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-F1 | Selected session shows **Timeline** from `recentActivities` (+ current) | Labels + optional duration (`endedAt - startedAt` or live age). |
| P0-F2 | Tool icon mapping is **SF Symbol generic**, monochrome | Map bash/shell → terminal; read → doc; edit/write → pencil; git → branch; unknown → circle. No brand-colored chips. |
| P0-F3 | “Last reply” | **Only** last finished activity / summary line — collapsible; no fake transcript. |

### P0-G — Config folder grid

| ID | Behavior | Acceptance |
|----|----------|------------|
| P0-G1 | Grid/list: Nocturnal root, sessions, responses, logs (if any), `~/.codex`, `~/.claude` when directories exist | Reveal in Finder via existing `NSWorkspace` pattern; disabled/hidden if absent. |
| P0-G2 | No network; no scanning other users’ homes | Uses `FileManager` existence checks only. |

### Explicitly **out of P0** (see §8)

- Usage meters, tokens, diffs, servers/ports, full multi-section forms, Always-Allow that mutates agent global settings files.

---

## 3. Core data model changes (exact types/fields)

### 3.1 `SessionStats` (new) — `Sources/NocturnalCore/Models/Session.swift` (or small new file)

```swift
public struct SessionStats: Codable, Sendable, Hashable, Equatable {
    public var toolUseCount: Int          // default 0
    public var filesTouchedCount: Int     // unique paths observed, default 0
    /// Bounded unique path keys for uniqueness (not for UI dump). Cap ~32.
    public var touchedPathKeys: [String]  // stored for hydrate continuity; UI ignores
    public var lastToolName: String?

    public static let empty = SessionStats(...)
    public static let maxTrackedPaths = 32
}
```

Add to `Session`:

```swift
public var stats: SessionStats
```

- CodingKeys + `decodeIfPresent` → `.empty` (backward compatible).
- Do **not** add token/diff fields even as optional zeros (avoids future UI temptation).

### 3.2 `ApprovalDecision` extension — `ApprovalAndQuestion.swift`

Already has `note: String?`. Add:

```swift
public var scope: ApprovalScope?   // optional for Codable back-compat
```

```swift
public enum ApprovalScope: String, Codable, Sendable, Hashable {
    case once           // default when nil
    case sessionTool    // "always allow this tool for this session" (Nocturnal-local sticky)
}
```

Keep wire shape additive; missing scope decodes as `once`.

### 3.3 Session sticky always-allow (local)

On `Session` (or inside `stats` / `rawMetadata`):

**Prefer explicit field:**

```swift
/// Tool names the user chose "always allow" for this session (local UI policy only).
public var sessionAlwaysAllowTools: Set<String> // Codable via sorted [String]
```

Store is the only mutator (via `applyLocalResponse` when `scope == .sessionTool`).

### 3.4 Presentation helpers (pure, Core or UI)

Prefer **Core pure formatting** for testability:

```swift
// Session+Presentation.swift or extend SessionActivity
public extension Session {
    var ageDescription: String          // from createdAt or updatedAt
    var statsMetaLine: String?          // "4 tools · 2 files" or nil if empty
}
public extension SessionActivity {
    var durationDescription: String?    // ended-started or nil
    var verbToken: String               // short label for pill
}
```

If keeping UI-only, put formatters in `SessionPresentation` but still unit-test via small Core helpers when possible.

### 3.5 Do **not** add

- `UsageMeter`, `TokenStats`, `DiffStats`, `LocalServer`, multi-`QuestionPrompt` queue — P2.

---

## 4. Decoder / store changes

### 4.1 Stats updates — `SessionActivityMapping` **or** `SessionStore.apply`

**Rule (single place, prefer mapping after activity apply):**

| Event | Stat effect |
|-------|-------------|
| `PreToolUse` | `toolUseCount += 1`; set `lastToolName`; if path extracted → unique path bookkeeping + `filesTouchedCount` |
| `PostToolUse` | Do **not** double-count tools if Pre already counted; may fill path if Pre lacked it |
| Approval / question / lifecycle | No tool count |

Path extraction (best-effort, mirror activity mapping):

- Top-level: `file_path`, `filePath`, `path`, `filepath`
- Nested `tool_input` object: same keys + `command` is **not** a file path

Unknown events: **no** invented stats.

### 4.2 Always-allow auto decision — `SessionStore.apply`

After building `decoded.approval` / setting `pendingApproval`:

```text
if let tool = approval.toolName,
   session.sessionAlwaysAllowTools.contains(normalized(tool)),
   allowLifecycleMutation {
  // Option A (recommended for fail-open honesty):
  // still set pendingApproval so UI can flash "auto-allowing", then
  // leave decision to UI/AppModel on snapshot observe
  // Option B: store does not auto-write responses (store must not I/O transport)
}
```

**Critical:** `SessionStore` must **not** call `ResponseTransport`. Auto-allow is:

1. Store records sticky set on local response with `scope == .sessionTool`.
2. **AppModel** on snapshot: if pending approval’s tool ∈ sticky set → call existing `approve(..., approved: true)` (writes transport + `applyLocalResponse`).

Document race: user can still Deny if they expand before auto fires; auto should be immediate Task on MainActor.

### 4.3 Decoders

- **No new event types** required for P0.
- Optional P1: richer `ApprovalRequest.detail` from nested `tool_input` stringify (Claude already does some).
- Preserve `raw` on approval/question as today.

### 4.4 `applyLocalResponse` for approval

When `decision.approved && decision.scope == .sessionTool`:

- Insert normalized `toolName` from **cleared** pending approval into `sessionAlwaysAllowTools`.
- If deny: do not add; optional future “forget” not needed.

Activity labels already set to Approved/Denied — keep.

### 4.5 Response transport

`FileResponseTransport` approval sidecars: add optional fields (additive):

```json
{
  "request_id": "...",
  "session_id": "...",
  "approved": true,
  "note": null,
  "scope": "sessionTool",
  "decided_at": "..."
}
```

Claude sidecar:

```json
"permission": "allow",
"scope": "sessionTool"
```

Do **not** claim Codex/Claude read these yet. Canonical `ResponseFileEnvelope` encodes full `ApprovalDecision` including new field automatically via Codable.

`AppModel.approve` signature:

```swift
func approve(
  _ request: ApprovalRequest,
  approved: Bool,
  note: String? = nil,
  scope: ApprovalScope = .once
) async -> Bool
```

---

## 5. UI surfaces to change

| File | Change |
|------|--------|
| `Sources/Nocturnal/Design/SessionPresentation.swift` | Verb coloring hooks, row meta line (`duration · stats`), pill line composition; **no neon**. |
| `Sources/Nocturnal/Views/PillView.swift` | Split verb `Text` + detail `Text`; semantic foreground for verb only. |
| `Sources/Nocturnal/Views/SessionRowView.swift` | Meta row: duration, tool/file counts, source chip; jump badge; keep attention styling. |
| `Sources/Nocturnal/Views/OverlayRootView.swift` (`ExpandedOverlayPanel`) | Header count + Folders/Settings buttons; optional approval banner host. |
| `Sources/Nocturnal/Views/ApprovalSheet.swift` | Banner copy, note field, Always allow toggle, improved detail chrome; shortcuts. |
| `Sources/Nocturnal/Views/SessionPanelView.swift` | Inline approval/question host when overlay style + attention; wire timeline under selection. |
| `Sources/Nocturnal/Views/SessionTimelineView.swift` (**new, small**) | `ForEach` activities; SF Symbol by label; duration. |
| `Sources/Nocturnal/Views/FoldersSheet.swift` (**new, small**) | Grid of local paths + reveal. |
| `Sources/Nocturnal/AppModel.swift` | `approve` note/scope; auto-allow Task; folder path helpers; open folders sheet state. |
| `Sources/Nocturnal/Design/DesignTokens.swift` | Only if a **semantic** token needed; avoid decorative colors. |

**Do not touch** (unless compile forces): forwarder, installer, socket, OverlayGeometry constants (unless pill text overflow — prefer truncate over resize).

### Brand rules for UI agents

- Black / gray / soft white chrome only.
- Amber = approval/question only; green = running/success pulse only; red = deny/fail only.
- Activity “verb color” in competitive product is cyan — **map to** `fgSecondary` or `accentSuccess` for running tools, **not** cyan/purple.
- No glass blur stacks, neon gradients, confetti, fake usage rings.

---

## 6. Response transport extensions

| Need | Change |
|------|--------|
| Deny with feedback | Use existing `ApprovalDecision.note`; UI collects text; transport already writes `"note"`. |
| Always allow | Add `ApprovalScope` on decision; sidecar JSON includes `"scope"`; envelope Codable follows. |
| Agent consumption | **Out of band / best-effort.** Status copy: “Recorded …”. Fail-open if agent ignores files. |
| Question multi-select | If P1 needs multi values: encode joined text or JSON in `QuestionAnswer.text` — **not P0**. |

Tests: extend `ResponseRoutingTests` for `scope` + `note` round-trip on file transport.

---

## 7. Implementation order (~1 hour)

### Phase 0 — Core (≈20–25 min) — `nocturnal-core`

1. Add `SessionStats`, `sessionAlwaysAllowTools`, Codable defaults.  
2. Increment stats in `SessionActivityMapping` (or store) with path helper.  
3. `ApprovalScope` + `ApprovalDecision.scope`.  
4. `applyLocalResponse` updates sticky set.  
5. Pure helpers: duration / stats meta / activity duration.  
6. Sidecar encode of `scope` in `FileResponseTransport`.  
7. Tests: `SessionActivityTests` or new `SessionStatsTests`; `ResponseRoutingTests`; persistence round-trip without stats field.

**Verify:** `swift test` (Core targets).

### Phase 1 — UI shell (≈25–30 min) — `nocturnal-ui`

1. `SessionPresentation` + `PillView` verb/detail.  
2. `SessionRowView` meta line + jump badge (bundle id / strategy hint from `JumpBackContext` — e.g. codex link → “Codex”, terminal bundle → monochrome icon).  
3. `ExpandedOverlayPanel` header toolbar + session count.  
4. `FoldersSheet` + AppModel path list (`PersistencePaths`, `~/.codex`, `~/.claude`).  
5. Approval UX: enhance `ApprovalSheet` + optional inline banner in panel for attention session.  
6. `AppModel.approve` note/scope + auto-allow observer.  
7. `SessionTimelineView` under selected row or below list when selection non-nil.  
8. Question sheet radio/Other polish only.

**Verify:** `swift build`, smoke with fixtures (`docs/simulation.md`).

### Phase 2 — Tests / polish (≈10 min)

1. Core tests green; fix Codable regressions.  
2. Manual: inject `Fixtures/codex/approval-required.ndjson` + Claude lifecycle.  
3. Optional: `Scripts/package_app.sh` if packaging paths used for folders helper.

### Agent split

| Agent | Owns | Does not |
|-------|------|----------|
| core | Models, mapping, store sticky, transport scope, unit tests | SwiftUI |
| ui | Pill/row/header/approval/question/timeline/folders, AppModel glue | Store mutation, inventing meters |

---

## 8. What to skip (and why)

| Feature | Tier | Why skip now |
|---------|------|--------------|
| Claude/Codex **5H/7D** usage meters + refresh | **P2** | No local quota API in hooks; inventing % is dishonest |
| Token ↑/↓ on rows | **P2** | Not in hook payloads |
| Diff +/− counts | **P2** | Not in hooks; Codex scanner is `session_meta` only |
| Full **LAST REPLY** transcript | **P2** | No streaming transcript channel |
| Structured multi-question wizard (sections, 1 of 2, checkbox groups) | **P1/P2** | Model is single `QuestionPrompt`; multi only via sequential events later |
| Local **servers/ports** (Next.js :3000 open/stop) | **P2** | Requires process/port scan + process control — out of hour + risk |
| Global Always Allow writing agent settings files | **P2** | Dangerous, non-fail-open, product-specific |
| Glass/neon island clone | **Never** | Brand + legal/product constraint |
| Fake empty usage placeholders | **Skip** | Prefer honest omission |

### P1 backlog (next session, not this hour)

- Richer tool_input decode into approval detail / file paths.
- Integration “chips” from tool names (github/bash/edit) monochrome.
- Multi-answer questions if payload gains `multi: true` + choices.
- Session detail pane with sticky timeline (not only selected strip).
- Optional best-effort read of local Claude/Codex usage **files** if discovered on disk (still no network) — only with real file evidence.

---

## 9. Risk notes

| Risk | Mitigation |
|------|------------|
| **Brand drift** toward competitor cyan/glass | Verb colors = existing `NocturnalPalette` only; design review vs `.impeccable.md` |
| **Fail-open** | No changes to forwarder exit code; transport failures surface status string; auto-allow still file-drop only |
| **Actor boundaries** | UI never mutates `Session`; only `store.apply` / `applyLocalResponse` / transport |
| **Lying about agent behavior** | Copy “Recorded approval/denial”; scope is local sticky + sidecar hint |
| **Double tool counts** | Count PreToolUse only (test) |
| **Auto-allow surprise** | Sticky is per-session tool name; user opted in via toggle; can still deny if pending races |
| **Tests writing real home** | Continue `NOCTURNAL_CONFIG_ROOT` / temp `PersistencePaths`; folder reveal uses real home only at runtime UI |
| **Persistence bloat** | Cap `touchedPathKeys` at 32; `recentActivities` already capped at 12 |
| **Keyboard conflicts** | Overlay A/D already global; sheet shortcuts must not fight TextField when note focused |

---

## 10. Verification commands

```bash
# From repo root
swift build
swift test

# Optional packaging
Scripts/package_app.sh   # → build/Nocturnal.app

# Simulation (manual): see docs/simulation.md
# Use Fixtures/codex/approval-required.ndjson + claude/session-lifecycle.ndjson
# Prefer NOCTURNAL_APP_SUPPORT / NOCTURNAL_SOCKET overrides — never write real agent dirs from tests
```

Success bar for the hour:

- [ ] `swift build` clean  
- [ ] `swift test` green (including new stats/scope tests)  
- [ ] Pill shows verb + live detail for PreToolUse  
- [ ] Row shows duration and tool count from hooks  
- [ ] Approval can Allow / Deny / Deny+note; Always-allow sticky works once  
- [ ] Timeline lists recent activities  
- [ ] Folders sheet reveals App Support  
- [ ] No usage meters / tokens / neon glass  

---

## Appendix A — Mapping competitive list → tier

| Video feature | Tier | Approach |
|---------------|------|----------|
| Compact notch drip + colored verb | **P0** | Existing drip + semantic verb color |
| Rich rows (action, duration, counts) | **P0** | Live line + stats + age; **omit** tokens/diff |
| Integration chips + jump badge | **P0** badge / **P1** chips | Jump from `JumpBackContext`; chips later |
| Header count + toolbar | **P0** | Settings + folders; **no** usage |
| 5H/7D meters + refresh | **P2** | Skip |
| Permission banner + plan/code + shortcuts | **P0** | Banner + detail + note; plan steps only if detail text already numbered |
| Always Allow / Reject feedback | **P0** | Local scope + note |
| Full-panel APPROVED success | **P0** light | Status/activity line only |
| Multi-question forms | **P1/P2** | Polish single prompt only |
| LAST REPLY + TIMELINE | **P0** timeline; last reply = last activity | |
| Local servers view | **P2** | Skip |
| Config folder grid | **P0** | Finder reveals |

## Appendix B — Suggested test cases (Core)

1. PreToolUse ×3 → `toolUseCount == 3`; PostToolUse does not make 4.  
2. PreToolUse with `file_path` A then A again → `filesTouchedCount == 1`.  
3. Session JSON without `stats` decodes empty.  
4. `applyLocalResponse` approve `scope: .sessionTool` → tool in `sessionAlwaysAllowTools`.  
5. Mismatched request id still no-op.  
6. Response file contains `scope` and `note` when set.  
7. Unknown event type does not change stats.

## Appendix C — File touch list (minimum)

**Core**

- `Models/Session.swift`  
- `Models/ApprovalAndQuestion.swift`  
- `Store/SessionActivityMapping.swift`  
- `Store/SessionStore.swift`  
- `Transport/ResponseTransport.swift`  
- `Tests/NocturnalCoreTests/SessionActivityTests.swift` (extend)  
- `Tests/NocturnalCoreTests/ResponseRoutingTests.swift` (extend)  

**UI**

- `Design/SessionPresentation.swift`  
- `Views/PillView.swift`  
- `Views/SessionRowView.swift`  
- `Views/OverlayRootView.swift`  
- `Views/ApprovalSheet.swift`  
- `Views/SessionPanelView.swift`  
- `AppModel.swift`  
- `Views/SessionTimelineView.swift` (new)  
- `Views/FoldersSheet.swift` (new)  

---

*End of plan. Execute Core first; do not expand scope into P2 during the hour.*
