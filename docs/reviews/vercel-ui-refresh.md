# Review notes — Vercel monochrome UI refresh

**Author:** nocturnal-ui  
**Date:** 2026-07-13  
**Scope:** Palette, compact pill chrome, expanded size, brand assets, demo removal, empty state

---

## Compact pill — square margins root cause

### Symptom

The compact floating pill showed a **rectangular backing / square shadow halo** around the capsule, reading as hard square margins even though the SwiftUI chrome was a capsule.

### Investigation

| Layer | Finding |
|-------|---------|
| `NSPanel.backgroundColor` | Already `.clear` |
| `NSPanel.isOpaque` | Already `false` |
| `NSPanel.hasShadow` | **`true`** — AppKit draws a **rectangular** window shadow around the entire `contentRect`, not the capsule silhouette |
| `NSHostingView` | Could paint an opaque default layer fill over the clear panel |
| SwiftUI `PillView` | Capsule fill + `.shadow` were correct; they sat *inside* the rectangular window shadow |

### Root cause (exact)

**`panel.hasShadow = true` on a borderless `NSPanel` produces a rectangular native drop shadow matching the window’s content rectangle.** Combined with a full-rect hosting view (and any residual opaque layer), this appears as square margins/backing around the capsule. The SwiftUI capsule shadow alone is fine; the **system window shadow** is not capsule-shaped.

### Fix

1. Set `panel.hasShadow = false` for compact and expanded modes.
2. Keep `backgroundColor = .clear`, `isOpaque = false`.
3. Force `NSHostingView` / content view: `wantsLayer = true`, `layer?.backgroundColor = clear`, `isOpaque = false`.
4. Rely on SwiftUI **capsule** fill, hairline stroke, and **capsule-shaped** `.shadow`.
5. `clipShape(Capsule)` + `compositingGroup()` on the pill; `Color.clear` host background in `OverlayRootView`.

### Regression coverage

`Tests/NocturnalCoreTests/OverlayGeometryTests.swift`:

- Compact size stays compact; expanded ideal is 520×620.
- Expanded size clamps to small visible frames.
- Documents compact chrome contract: non-opaque, **no window shadow**, clear background.

AppKit pixel-level shadow shape is not unit-testable under CLT; the configuration contract is locked instead.

---

## Other changes (summary)

| Item | Change |
|------|--------|
| Palette | Warm nocturnal → monochrome black/white/gray; semantic color only for state meaning |
| Expanded panel | Ideal **520×620**, clamped to active screen `visibleFrame` |
| Brand | Owl mark + app icon as SPM resources; template menu-bar item; packaged `Icon.icns` |
| Product demo | Fully removed (`AgentSource.demo`, seeds, decoder path, UI CTAs); obsolete `demoMode` settings JSON key still ignored on decode |
| Empty state | Owl mark, hook copy, Settings / copy setup / reveal helper — all wired |

---

## Verification

```bash
swift build
swift test
Scripts/package_app.sh
# Inspect Info.plist CFBundleIconFile, Resources/Icon.icns, Resources/Brand/*
```
