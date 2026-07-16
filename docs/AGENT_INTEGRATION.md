# Agent Integration Model

Nocturnal is a **local multi-agent companion**, not a single-product UI. This
document defines how any coding agent plugs in — Codex, Claude Code, OpenCode
today; Cursor, Kimi Code, Grok Build, Agy, and others as adapters mature.

## Design principle

| Layer | Responsibility |
|-------|----------------|
| **Agent native world** | Hooks, plugins, ACP, IDE APIs, logs |
| **Adapter** | Map native → Nocturnal Agent Protocol (NAP) |
| **`EventEnvelope` + socket** | Universal ingress (NDJSON) |
| **`SessionStore` + island** | Product-agnostic UI |

There is **no** “one scraper for every app.” There **is** one contract; each
product implements an adapter (or posts envelopes directly).

## Integration tiers

| Tier | What you get | Requirements |
|------|----------------|--------------|
| **A – Envelope bridge** | Live sessions in island / list | Emit `EventEnvelope` NDJSON to the socket |
| **B – Lifecycle + brand** | Decoder polish, recovery scan, marks | `AgentProfile` + optional scanner |
| **C – Bidirectional** | Notch Deny/Allow, answers | Decision transport (stdout / HTTP / file) |

UI **never** shows Deny/Allow unless:

```text
profile.capabilities.permissions
  && profile.decisionTransport.supportsInlineDecision
```

## Catalog (`AgentRegistry`)

| id | Source | Tier today | Decision |
|----|--------|------------|----------|
| `codex` | `.codex` | C | stdout JSON (hook forwarder) |
| `claude` | `.claude` | C | stdout JSON |
| `opencode` | `.opencode` | C | HTTP permission API |
| `cursor` | `.cursor` | A | none |
| `kimi` | `.kimi` | A | none |
| `grok-build` | `.grokBuild` | A | none |
| `agy` | `.agy` | A | none |
| `generic` | `.unknown` | A | response file (optional) |
| `unknown` | `.unknown` | A | none |

Capabilities live in `AgentCapabilities`. Lookup:

```swift
AgentRegistry.profile(for: session)
AgentRegistry.profile(parsing: "cursor")
AgentAdapterCatalog.adapter(for: .kimi)
```

## Nocturnal Agent Protocol (NAP)

Canonical `eventType` values (`CanonicalAgentEvent`):

- Lifecycle: `session.started`, `session.updated`, `session.completed`, `session.failed`, `session.cancelled`, `session.reconciled`
- Turns: `turn.started`, `turn.completed`
- Tools: `tool.started`, `tool.completed`
- Attention: `permission.asked`, `permission.resolved`, `question.asked`, `question.answered`

Native names (e.g. `PermissionRequest`, `PreToolUse`) continue to work via
existing product decoders and `CanonicalAgentEvent.normalize(_:)`.

### Minimal Tier A line

```json
{
  "v": 1,
  "id": "00000000-0000-4000-8000-000000000001",
  "source": "cursor",
  "eventType": "session.started",
  "sessionId": "cursor-abc",
  "timestamp": "2026-07-16T12:00:00Z",
  "payload": {
    "title": "Refactor auth",
    "cwd": "/Users/you/project"
  },
  "raw": {}
}
```

Pipe via:

```bash
echo '…json…' | nocturnal-hook-forwarder --wrap-source cursor
# or write NDJSON directly to $NOCTURNAL_SOCKET / default ipc.sock
```

## Adapter SPI

```swift
protocol AgentAdapter {
  var profile: AgentProfile { get }
}

protocol HookInstallingAdapter: AgentAdapter {
  var hookProduct: HookProduct? { get }
}

protocol HTTPPermissionAdapter: AgentAdapter {
  func shouldDeliverHTTPPermission(for request: ApprovalRequest) -> Bool
}
```

Built-ins: `CodexAgentAdapter`, `ClaudeAgentAdapter`, `OpenCodeAgentAdapter`,
`EnvelopeBridgeAdapter` for Tier A catalog entries.

## Adding a new agent

1. Add `AgentSource` case (optional if pure string id + `.unknown` is enough).
2. Register `AgentProfile` in `AgentRegistry` with honest capabilities.
3. Ship Tier A by documenting the envelope shape (no app binary change required
   if `source` parses to an existing profile or ad-hoc id).
4. Tier B: product decoder + optional recovery scanner.
5. Tier C: decision transport + gate UI already works once `permissions` is true.

## Fail-open

Missing Nocturnal, missing adapter, or `decisionTransport == .none` must never
block the agent. Hooks/plugins timeout and return empty / agent-native prompts.

## Related

- `docs/HOOK_SCHEMAS.md` — implemented native event types
- `docs/ARCHITECTURE.md` — socket, store, packaging
- `docs/simulation.md` — fixture recipes
