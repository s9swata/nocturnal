# Peer reviews

Review notes for cross-agent review live in this directory.

## Naming

```
docs/reviews/YYYY-MM-DD_<reviewer>_<subject>.md
```

Examples:

- `2026-07-13_architect_core.md` — architect reviewing core implementation  
- `2026-07-14_core_ui.md` — core reviewing UI handoff  
- `2026-07-15_qa_core.md` — QA reviewing core test seams  

## Template

```markdown
# Review: <subject>

- **Reviewer:** nocturnal-architect | nocturnal-core | nocturnal-ui | nocturnal-qa
- **Date:** YYYY-MM-DD
- **Revision / branch:** <git rev or branch>
- **Scope:** files / modules reviewed

## Summary

One short paragraph: ship / revise / block.

## Findings

### P0 — must fix
- …

### P1 — should fix before merge
- …

### P2 — nice to have
- …

## Contract checklist

- [ ] Builds (`swift build`)
- [ ] Tests (`swift test`) relevant to change
- [ ] Unknown hook events fail soft
- [ ] No telemetry / accounts / cloud
- [ ] No writes to real `~/.codex` / `~/.claude` in tests
- [ ] Sendable / actor boundaries respected
- [ ] Handoff doc updated if public API changed

## Open questions

- …

## Decision

**Approve** | **Approve with nits** | **Request changes**
```

## Severity

| Level | Meaning |
|-------|---------|
| P0 | Build break, data loss risk, hooks blocking agents, privacy violation |
| P1 | Incorrect contract, flaky tests, a11y regression on primary flows |
| P2 | Style, polish, non-blocking docs |

## Process

1. Author leaves `*_HANDOFF.md` at repo root when a milestone finishes.  
2. Reviewer reads handoff + diff, runs build/tests as needed.  
3. Reviewer writes a notes file using the template above.  
4. Author addresses P0/P1 and links the review file in a short reply note (optional).
