# UI_HANDOFF — NocturnalApp shell MVP

**Author:** nocturnal-ui  
**Date:** 2026-07-13  
**Status:** Production UI MVP implemented; `swift build` clean.

---

## What landed

| Surface | Status |
|---------|--------|
| Floating pill (notch-aware / top-center) | AppKit `NSPanel` non-activating overlay |
| Expandable session panel | Same panel resizes; SwiftUI list + actions |
| Session list | Stable `Session.id`, attention-first sort, state badges |
| Approval / question actions | Wired to `ResponseTransport` + `SessionStore.applyLocalResponse` |
| Settings window | Quiet, sessions, hooks/paths, about/privacy |
| MenuBarExtra | Sessions, demo, settings, quit |
| Keyboard navigation | ↑/↓ select; A/D approve/deny; app menu commands |
| Accessibility | Labels, combined rows, VO actions, status live text |
| Reduced motion | `AppSettings.reduceMotion` ∪ system Reduce Motion |
| Demo mode | First-class empty state + reload; no disk writes |

---

## Scenes

| Scene | ID / entry | Content |
|-------|------------|---------|
| `MenuBarExtra` | system image `moon.stars.fill`, `.window` style | `MenuBarView` → `SessionPanelView` |
| `Settings` | system Settings (⌘,) | `SettingsView` (General / Hooks / About tabs) |
| `Window` | `"main"` | `RootView` — dev / non-agent status window |
| Overlay (AppKit) | not a SwiftUI `Scene` | `OverlayController` hosts `OverlayRootView` → `PillView` / expanded panel |

Companion policy: menu bar is primary; floating pill is optional (`showFloatingPill`); main window is available for `swift run` / debugging without LSUIElement packaging.

---

## File map

```
Sources/Nocturnal/
  NocturnalApp.swift          # Scenes + Commands
  AppModel.swift              # @Observable façade → Core
  Design/
    DesignTokens.swift        # Palette, layout, motion
    SessionPresentation.swift # Badges, sort, a11y labels
  Overlay/
    OverlayController.swift   # Non-activating NSPanel, geometry
  Views/
    OverlayRootView.swift     # Pill ↔ expanded host content
    PillView.swift
    SessionPanelView.swift    # List + empty + sheets
    SessionRowView.swift      # Row, badge, actions
    ApprovalSheet.swift       # Approval + Question sheets
    MenuBarView.swift
    SettingsView.swift
    RootView.swift
```

---

## Core wiring (`AppModel`)

| Concern | API |
|---------|-----|
| Bootstrap | `PersistencePaths.resolve()`, `SessionPersistence`, `SettingsStore`, hydrate / demo |
| Observation | `await store.snapshots()` → `snapshot` |
| Live events | `EventSocketServer` on resolved socket (`NOCTURNAL_SOCKET` or paths) |
| Approve / deny | `FileResponseTransport.submit(.approval)` + `store.applyLocalResponse` |
| Answer | same with `.question` |
| Demo | `SessionStorePolicy(autoPersist: false)` + `DemoSessions.load` |
| Jump back | `JumpBackCoordinator().jump(using:)` |
| Settings | `SettingsStore.save` |

UI **never** mutates session maps directly.

### UI-only state (not in Core)

- `isOverlayExpanded`, `selectedSessionID`
- Approval / question sheet session ids
- Mirrored `snapshot`, `settings`, `statusMessage`, path displays

### Derived lists

```swift
visibleSessions // attention-first, then updatedAt, capped by maxVisibleSessions
attentionCount  // snapshot.sessionsNeedingAttention.count
prefersReducedMotion // settings ∪ system
```

---

## Accessibility coverage

| Control / region | Coverage |
|------------------|----------|
| Pill | Label with mode/count; hint to expand |
| Expanded panel | Container label; Escape collapses |
| Session rows | Combined title + state + source + summary; selected trait |
| Approve / Deny | Button labels; VO actions on row |
| Jump back | Button + VO action |
| Answer sheet | Focused field; Send disabled when empty |
| Approval sheet | Default focus on Approve; risk/summary/detail labeled |
| Status line | `Status: …` accessibility label (menu, window, overlay) |
| Settings | Sectioned forms; copy commands labeled |
| Keyboard | ↑/↓ in menu/overlay/window; A/D approve/deny; ⌘⌥A / ⌘⌥D; ⌘J/K select; ⌘⇧P expand pill; Escape collapse |

Dynamic Type: system text styles (`.headline`, `.subheadline`, `.caption`, `.caption2`) — no fixed primary font sizes.

---

## Motion

- Expand/collapse ≈ 0.22s ease-in-out (AppKit frame + SwiftUI opacity)
- Status / selection: 0.2s when motion allowed
- Attention glow: single soft breath on pill when count > 0
- When reduced motion: instant frame changes, opacity-only transitions, no breath loop

---

## Brand

Follows `.impeccable.md`:

- Warm near-black base / elevated charcoal
- Soft amber attention (not alarm red by default)
- No neon, cyan/purple gradients, glassmorphism, or island-copy chrome
- SF Symbol `moon.stars.fill` interim mark

---

## How to run

```bash
swift build
swift run Nocturnal
# optional simulation env
export NOCTURNAL_APP_SUPPORT=/tmp/nocturnal-ui-test
export NOCTURNAL_SOCKET=/tmp/nocturnal-ui-test/ipc.sock
```

Settings → Hooks shows paths and copy-ready `nocturnal-setup` / forwarder commands.

Packaged app: `Scripts/package_app.sh` → `build/Nocturnal.app` (architect-owned).

---

## Known limits / follow-ups

1. **Non-activating panel keyboard** — key focus works best once the expanded panel is clicked; full global hotkeys would need an event tap (out of scope).
2. **Main window** always registered — packaging may hide Dock icon via `LSUIElement`; window remains useful for `swift run`.
3. **Sound** uses system `Tink` only when `soundEnabled` (default off).
4. **Socket path** — Core `PersistencePaths.resolve()` owns `NOCTURNAL_SOCKET`; UI uses `paths.socketURL` only (no env re-parse in AppModel).
5. **Multi-display** — pill follows mouse-containing screen; no per-display sticky preference yet.
6. **Question choices** — freeform + choice chips; no multi-select.

---

## Peer review

`docs/reviews/ui-on-core.md` — core API fitness for UI integration.

---

## Suggested next (QA / polish)

1. VoiceOver pass on menu bar window + overlay expand.
2. Simulate approval envelope → Approve writes `responses/` and clears badge.
3. Toggle Reduce Motion in System Settings and confirm pill expand is instant.
4. Optional: hide Dock window when packaged as agent-only companion.
