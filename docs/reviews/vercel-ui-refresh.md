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

---

## Overlay constraint-cycle crash + width compression (2026-07-13)

### Symptom (packaged binary, macOS 26.2)

- App aborts after launch with uncaught **`NSGenericException`**.
- Reason: *The window has been marked as needing another Update Constraints in Window pass, but it has already had more passes than there are views.*
- Faulting window: `NSPanel` ≈ **225 × 218**.
- Stack: `NSHostingView.updateAnimatedWindowSize` → `windowDidLayout` → `setFrameSize` → `invalidateSafeAreaInsets` → `setNeedsUpdateConstraints`.
- Expanded panel also **narrowed** toward empty-state fitting width instead of staying **520 × 620** on a 1440-pt display.

### Root cause (exact)

`OverlayController` owned compact **228 × 36** and expanded ideal **520 × 620** via `NSPanel.setFrame`, but the `NSHostingView` still participated in **automatic window sizing** (default `sizingOptions` including min / intrinsic / max content size). Empty-state SwiftUI intrinsic size (~225 × 218) drove `updateAnimatedWindowSize`, which rewrote the panel frame, invalidated safe-area insets, and re-entered Auto Layout until the constraint-pass limit. A post-`setFrame` manual `hostingView.frame = …` assignment compounded the fight. Simultaneous SwiftUI size animation + AppKit frame animation restarted layout mid-cycle.

### Fix

1. **`NSPanel` is the single source of truth for dimensions.**
2. Set `hosting.sizingOptions = []` (empty `NSHostingSizingOptions`) so intrinsic content cannot mutate the panel.
3. `safeAreaRegions = []` (macOS 13.3+) to avoid safe-area invalidation thrash on the borderless panel.
4. Frame-based host: `translatesAutoresizingMaskIntoConstraints = true`, `autoresizingMask = [.width, .height]` — content fills the panel content rect without Auto Layout window sizing.
5. **Remove** redundant `hostingView.frame` writes after `panel.setFrame`.
6. Stable create order: configure host → assign `contentView` → `setFrame` once.
7. Expand/collapse ordering: grow panel before flipping model expanded; collapse content before shrinking frame. AppKit frame remains the sole geometry animation path; SwiftUI only opacity-transitions content. Respect Reduce Motion.
8. Keep clear non-opaque panel/host and `hasShadow = false` (capsule shadow fix intact).

### Regression coverage

- Core: `OverlayGeometry` placement + clamp (including 1440-pt display keeps 520×620).
- Core: `OverlayHostLayoutPolicy` — empty sizing-options raw value, chrome flags, negative cases.
- UI: `OverlayController.HostLayoutConfiguration` / `hostLayoutConfiguration` production helper for live assertion.

### Verification (packaged)

```bash
swift test
Scripts/package_app.sh
git diff --check
codesign --verify --verbose=2 build/Nocturnal.app
# Launch binary ≥30s, expand (⌘⇧P), confirm NSPanel 520×620, quit cleanly
```
