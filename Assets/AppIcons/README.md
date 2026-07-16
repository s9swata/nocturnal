# Nocturnal app icons

Generated from `Sources/Nocturnal/Resources/Brand/nocturnal-app-icon.png` via:

```bash
Scripts/generate_app_icons.sh
```

## Stages

| Stage | Badge | Display name | When used |
|-------|-------|--------------|-----------|
| `production` | none | Nocturnal | `Scripts/package_app.sh` (release) |
| `staging` | amber **STG** | Nocturnal (Staging) | `NOCTURNAL_ICON_STAGE=staging` |
| `dev` | grey **DEV** | Nocturnal (Dev) | `CONF=debug` or `NOCTURNAL_ICON_STAGE=dev` |

Each stage has:

- `icon-1024.png` / `AppIcon.png` — master art
- `Nocturnal.iconset/` — macOS sizes
- `Icon.icns` — packaged app icon

## Web / PWA favicons

Also written under `static/icons/{production,staging,dev}/`:

- `favicon.ico`, `icon-*.png`, `apple-touch-icon.png`
- `site.webmanifest` (name includes stage)
- `static/head-icons.html` — stage-aware `<head>` snippet
- `static/icons/verify.html` — open in a browser to confirm the **tab** icon flips per stage

```bash
open static/icons/verify.html
```

## Packaging

```bash
Scripts/generate_app_icons.sh          # regenerate from logo
Scripts/package_app.sh                 # production icon
NOCTURNAL_ICON_STAGE=staging Scripts/package_app.sh
CONF=debug Scripts/package_app.sh      # dev badge
```

## Note

Nocturnal is a **macOS** companion — there is no in-app HTML chrome. The `static/` set is for docs/landing pages; the `.icns` sets drive Dock / Finder / menu-bar process icons.
