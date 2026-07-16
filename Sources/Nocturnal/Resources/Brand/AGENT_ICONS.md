# Agent brand marks

Monochrome identification marks for supported coding agents.

| File | Product | Source |
|------|---------|--------|
| `agent-openai` | Codex (OpenAI) | [Simple Icons](https://simpleicons.org/) `openai` (CC0 1.0) |
| `agent-claude` | Claude Code | [Simple Icons](https://simpleicons.org/) `claude` (CC0 1.0) |
| `agent-opencode` | OpenCode | Official-style square mark as published on [opencode.ai/brand](https://opencode.ai/brand) / community static SVG (Lobe Icons set) |
| `agent-cursor` | Cursor | [Simple Icons](https://simpleicons.org/) `cursor` (CC0 1.0) |
| `agent-grok` | Grok Build | Original monochrome spark template (not a trademark clone) |

Rendered PNGs are black-on-transparent templates for SwiftUI `.template` tinting.
Trademarks belong to their respective owners; used here only to identify third-party products.

## Adding a mark

1. Add `agent-<id>.svg` (24×24 viewBox, `fill="#000000"`) under this folder **and** `Assets/Brand/`.
2. Rasterize: `rsvg-convert -w 128 -h 128 agent-<id>.svg -o agent-<id>.png`
3. Wire `BrandAssets.agentMarkResourceName(for:)` + package allow-list in `Scripts/package_app.sh`.
