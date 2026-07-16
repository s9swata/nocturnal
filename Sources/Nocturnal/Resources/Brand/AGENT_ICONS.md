# Agent brand marks

**Runtime format: PNG only.**  
`BrandAssets` loads `agent-*.png` via `NSImage` and sets `isTemplate = true` for monochrome tinting. SVG files are not used by the app.

## Current marks (favicontools)

Regenerated with [favicontools](https://favicontools.com) MCP `generate_iconset` → download `icon-1024x1024.png` → black-on-transparent template PNGs.

| PNG (runtime) | Product | favicontools source |
|---------------|---------|---------------------|
| `agent-openai.png` | Codex | `simple-icons:openai` |
| `agent-claude.png` | Claude Code | `simple-icons:claude` |
| `agent-opencode.png` | OpenCode | `simple-icons:opencode` |
| `agent-cursor.png` | Cursor | `simple-icons:cursor` |
| `agent-grok.png` | Grok Build | Design asset `icon-1024x1024.png` (data URL) |

Also kept: `@2x` (256) and `-1024` masters next to each mark.

## Refresh

```bash
Scripts/fetch_agent_icons_favicontools.sh
# optional Grok logo override:
GROK_LOGO="/path/to/icon-1024x1024.png" Scripts/fetch_agent_icons_favicontools.sh
```

## Packaging

`Scripts/package_app.sh` copies the production allow-list of agent **PNGs** into `Nocturnal.app/Contents/Resources/Brand/`.
