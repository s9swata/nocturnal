# UI_HANDOFF — NocturnalApp shell

**Author:** nocturnal-ui  
**Date:** 2026-07-13  
**Status:** Monochrome owl brand + full demo purge + packaging allow-list; `swift build` / package clean.

---

## What landed

| Surface | Status |
|---------|--------|
| Floating pill (notch-aware / top-center) | AppKit `NSPanel` non-activating; **capsule-only** chrome (no rect shadow) |
| Expandable session panel | ~520×620 ideal, clamped to visible screen |
| Session list | Stable `Session.id`, attention-first sort, state badges |
| Approval / question actions | Wired to `ResponseTransport` + `SessionStore.applyLocalResponse` |
| Settings window | Quiet, sessions, hooks/paths, about/privacy |
| MenuBarExtra | Template owl mark; sessions; settings; quit |
| Empty state | Owl mark + setup actions (Settings, copy command, reveal helper) |
| Keyboard navigation | ↑/↓ select; A/D approve/deny; app menu commands |
| Accessibility | Labels, combined rows, VO actions, status live text |
| Reduced motion | `AppSettings.reduceMotion` ∪ system Reduce Motion |
| Brand assets | SPM `Resources/Brand` + packaged `.icns`; runtime `applicationIconImage` |

**Removed:** product demo mode entirely (`AgentSource.demo`, settings, menus, seeds, CTAs). Obsolete `demoMode` settings key still ignored on decode.

---

## Scenes

| Scene | ID / entry | Content |
|-------|------------|---------|
| `MenuBarExtra` | template owl mark, `.window` style | `MenuBarView` → `SessionPanelView` |
| `Settings` | system Settings (⌘,) | `SettingsView` (General / Hooks / About tabs) |
| `Window` | `"main"` | `RootView` — dev / non-agent status window |
| Overlay (AppKit) | not a SwiftUI `Scene` | `OverlayController` hosts `OverlayRootView` → `PillView` / expanded panel |

Companion policy: menu bar is primary; floating pill is optional (`showFloatingPill`); main window is available for `swift run` / debugging without LSUIElement packaging.

---

## File map

```
Sources/Nocturnal/
  NocturnalApp.swift          # Scenes + Commands + menu bar label + app icon
  AppModel.swift              # @Observable façade → Core
  Design/
    DesignTokens.swift        # Monochrome palette; layout sizes from OverlayGeometry
    BrandAssets.swift         # Owl mark / app icon loading + views
    SessionPresentation.swift # Badges, sort, a11y labels
  Overlay/
    OverlayController.swift   # Non-activating NSPanel; uses Core OverlayGeometry
  Views/
    OverlayRootView.swift     # Pill ↔ expanded host content
    PillView.swift
    SessionPanelView.swift    # List + empty + sheets
    SessionRowView.swift
    ApprovalSheet.swift
    MenuBarView.swift
    SettingsView.swift
    RootView.swift
  Resources/Brand/
    nocturnal-owl-mark.png
    nocturnal-app-icon.png
```

---

## Core wiring (`AppModel`)

| Concern | API |
|---------|-----|
| Bootstrap | `PersistencePaths.resolve()`, `SessionPersistence`, `SettingsStore`, hydrate + socket |
| Observation | `await store.snapshots()` → `snapshot` |
| Live events | `EventSocketServer` on resolved socket |
| Approve / deny | `FileResponseTransport.submit(.approval)` + `store.applyLocalResponse` |
| Answer | same with `.question` |
| Jump back | `JumpBackCoordinator().jump(using:)` |
| Settings | `SettingsStore.save` |
| Empty-state actions | `copySetupCommand`, `revealSetupHelper`, `openSettings` (env) |
| Setup command | `SetupCommandFormatting.installAllCommand(binaryPath:)` — shell-quotes packaged paths |
| Reveal App Support | `canRevealAppSupport` after `PersistencePaths.resolve`; unavailable status otherwise |
| Approve / answer | `approve` / `answer` return `Bool` success; sheets dismiss only on success |

UI **never** mutates session maps directly.

### UI-only state (not in Core)

- `isOverlayExpanded`, `selectedSessionID`
- Approval / question sheet session ids
- Mirrored `snapshot`, `settings`, `statusMessage`, path displays

---

## Accessibility coverage

| Control / region | Coverage |
|------------------|----------|
| Pill | Label with count/listening; hint to expand; opacity-only attention breath |
| Expanded panel | Container label; Escape collapses |
| Session list | Container label; keyboard-nav hint (↑/↓, A/D) |
| Session rows | Combined title + state + source + summary; selected trait; **no** per-row A/D shortcuts |
| Approve / Deny | Button labels; VO actions on row; centralized A/D on overlay + ⌘⌥A/D menu |
| Empty state | Container label; Settings / copy / reveal; copy hint is outcome-based; command as a11y value |
| Jump back | Button + VO action |
| Answer sheet | Focused field; Send disabled when empty/in-flight; **⌘↩** sends (Return stays newline) |
| Approval sheet | Default focus on Approve; Return = default action; dismiss only after successful submit |
| Status line | `Status: …` accessibility label (menu, window, overlay) |
| Settings | Sectioned forms; prefs disabled until `isBootstrapped`; Reveal App Support gated on resolved path |
| Keyboard | ↑/↓; A/D (overlay); ⌘⌥A / ⌘⌥D; ⌘J/K; ⌘⇧P expand pill; Escape collapse |

---

## Motion

- Expand/collapse ≈ 0.22s ease-in-out (AppKit frame + SwiftUI opacity)
- Status / selection: 0.2s when motion allowed
- Attention glow: soft breath on pill when count > 0
- When reduced motion: instant frame changes, opacity-only transitions, no breath loop

---

## Brand

Follows `.impeccable.md`:

- Vercel-inspired monochrome (black / white / neutral grays)
- Semantic amber/red/green only for approval / failure / success
- Owl mark template in menu bar; full-bleed icon → `Icon.icns`
- Runtime: `NocturnalAppDelegate` sets `NSApplication.shared.applicationIconImage` from `BrandAssets.appIconNSImage` (covers `swift run`)
- Packaging: `package_app.sh` copies **only** `nocturnal-app-icon.png` + `nocturnal-owl-mark.png` into `Resources/Brand` (no working chroma files)
- No neon, gradients, glassmorphism, or rectangular pill chrome

---

## Compact pill chrome fix

See `docs/reviews/2026-07-13_ui_vercel-refresh.md`.

**Root cause:** `NSPanel.hasShadow = true` draws a rectangular system shadow around the content rect; any opaque hosting fill compounds the “square margin” look.

**Fix:** clear non-opaque panel, `hasShadow = false`, clear `NSHostingView` layer, SwiftUI capsule fill + capsule shadow only.

---

## Overlay geometry ownership (constraint-cycle crash)

See `docs/reviews/2026-07-13_ui_vercel-refresh.md` (section *Overlay constraint-cycle crash*).

**Root cause:** `NSHostingView` automatic window sizing (`updateAnimatedWindowSize` via default `sizingOptions`) fought manual `NSPanel.setFrame`, compressed empty state to ~225×218, narrowed expanded width, and looped Auto Layout until `NSGenericException`.

**Fix:** `sizingOptions = []`, frame-based autoresizing host, no post-`setFrame` content-frame writes, AppKit-only size animation, Core `OverlayGeometry` + `OverlayHostLayoutPolicy` contracts. Compact **228×36**, expanded ideal **520×620** with screen clamp.

---

## How to run

```bash
swift build
swift test
swift run Nocturnal
Scripts/package_app.sh
open build/Nocturnal.app
```

Settings → Hooks shows paths and copy-ready `nocturnal-setup` / forwarder commands.

---

## Known limits / follow-ups

1. **Non-activating panel keyboard** — key focus works best once the expanded panel is clicked.
2. **Main window** always registered — packaging may hide Dock icon via `LSUIElement`.
3. **Sound** uses system `Tink` only when `soundEnabled` (default off).
4. **Multi-display** — pill follows mouse-containing screen; no per-display sticky preference yet.
5. **Overlay geometry unit tests** live in Core as layout contracts (AppKit shadow shape is not unit-testable under CLT).
