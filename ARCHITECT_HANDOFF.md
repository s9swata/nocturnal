# Architect handoff

Scaffold complete for Nocturnal MVP. Targets compile under Swift 6.2 / macOS 14+.  
**Do not commit from agents unless the user requests it.**

## Modules

| Target | Path | Status |
|--------|------|--------|
| NocturnalCore | `Sources/NocturnalCore/` | Public API + working skeleton implementations |
| Nocturnal | `Sources/Nocturnal/` | Minimal MenuBarExtra + window + settings shell |
| nocturnal-hook-forwarder | `Sources/nocturnal-hook-forwarder/` | Fail-open CLI |
| nocturnal-setup | `Sources/nocturnal-setup/` | Install/uninstall/status CLI (sidecars) |
| NocturnalCoreTests | `Tests/NocturnalCoreTests/` | Baseline Swift Testing suite |

---

## nocturnal-core — implement next

### Priority 1 — productionize IPC & decode

| File / type | Work |
|-------------|------|
| `Socket/EventSocket.swift` → `EventSocketServer` | Harden accept loop cancellation, backpressure, multi-client lifecycle; consider `Network.framework` NWListener unix; structured logging |
| `Socket/EventSocket.swift` → `LocalUnixListener` | Path length checks already present; add connect timeout for client; abstract for tests |
| `Decoding/CodexEventDecoder.swift` | Align field names with **actual** Codex hook payloads once verified; keep unknown passthrough |
| `Decoding/ClaudeEventDecoder.swift` | Add raw Claude stdin → `EventEnvelope` normalizer if hooks don’t emit envelope shape |
| `Decoding/EventDecoder.swift` | Optional metrics: unknown event counts |

### Priority 2 — store & persistence

| File / type | Work |
|-------------|------|
| `Store/SessionStore.swift` | Cap session count; prune terminal sessions; disk hydrate on launch via `SessionPersistence` |
| `Persistence/SessionPersistence.swift` | Wire into app bootstrap; corruption recovery |
| `Persistence/PersistencePaths.swift` | Already defined layout — keep stable |
| `Settings/AppSettings.swift` / `SettingsStore` | Migrate schema if fields change; observe system Reduce Motion |

### Priority 3 — responses & jump-back

| File / type | Work |
|-------------|------|
| `Transport/ResponseTransport.swift` | Optional reply socket; agent-specific writers |
| `JumpBack/JumpBackStrategy.swift` | Real AppleScript/CLI tab selection for Terminal/iTerm; verify Ghostty bundle id; Codex deep link scheme confirmation |

### Priority 4 — hooks CLI

| File / type | Work |
|-------------|------|
| `Hooks/HookInstaller.swift` | Merge into real Codex/Claude config formats (not only sidecars); document exact paths; dry-run flag |
| `Hooks/HookForwarderProtocol.swift` | Optional envelope wrap when stdin is non-envelope JSON; connect timeout |
| `Sources/nocturnal-hook-forwarder/main.swift` | Keep fail-open; add `--wrap-source codex\|claude` if needed |
| `Sources/nocturnal-setup/main.swift` | `--dry-run`, per-product native config merge |

### Public types already defined (extend, don’t rename lightly)

- `SessionState`, `AgentSource`, `Session`, `SessionID`, `JumpBackContext`
- `EventEnvelope`, `JSONValue`
- `ApprovalRequest`, `QuestionPrompt`, `AgentResponse`, `ApprovalDecision`, `QuestionAnswer`
- `SessionStore`, `SessionStoreSnapshot`, `DecodedEvent`
- `EventDecoding`, `CompositeEventDecoder`, `CodexEventDecoder`, `ClaudeEventDecoder`, `DemoEventDecoder`
- `SocketPaths`, `EventSocketServer`, `EventSocketClient`
- `PersistencePaths`, `SessionPersistence`, `SettingsStore`, `AppSettings`
- `JumpBackCoordinator`, `JumpBackStrategy` (+ concrete strategies)
- `ResponseTransporting`, `FileResponseTransport`, `InMemoryResponseTransport`
- `HookForwarding`, `FailOpenHookForwarder`, `HookInstaller`, `HookProduct`
- `DemoSessions`

### Open contracts (core)

1. **Native hook merge**: sidecar only today; real `~/.codex` / Claude settings merge TBD  
2. **Claude raw stdin shape**: confirm and implement normalizer  
3. **Codex deep link URL scheme**: confirm production scheme for `CodexDeepLinkStrategy`  
4. **Response consumption**: how agents read `responses/*.json` (poll vs plugin)  
5. **Envelope versioning**: bump `EventEnvelope.currentSchemaVersion` policy  

### Tests to add

- Socket round-trip (temp path)  
- Claude PreToolUse permission matrix  
- Setup merge once native configs exist  
- Jump-back strategy selection unit tests (mock NSWorkspace if needed)

### Testing note (CLT vs Xcode)

Scaffold tests use **XCTest** because Apple’s **Swift Testing** macros / `_Testing_Foundation` cross-import are incomplete under **Command Line Tools only** (no full Xcode). When Xcode is installed, nocturnal-qa/core should migrate `NocturnalCoreTests` to Swift Testing (`import Testing`, `#expect`, `@Test`) per `swift-testing-pro`.

Leave **`CORE_HANDOFF.md`** when done.

---

## nocturnal-ui — implement next

### Priority 1 — primary surfaces

| File | Work |
|------|------|
| `NocturnalApp.swift` | Scene policy: LSUIElement companion; when to show Window |
| `AppModel.swift` | Overlay lifecycle; system Reduce Motion; sound hooks |
| `Views/SessionPanelPlaceholder.swift` | Real expandable session panel; attention sorting |
| `Views/MenuBarView.swift` | Polish, keyboard, empty/error states |
| `Overlay/OverlayController.swift` | Notch-aware / top-center pill; non-activating expansion; multi-display |

### Priority 2 — settings & demo

| File | Work |
|------|------|
| `Views/SettingsPlaceholderView.swift` | Match `.impeccable.md` tokens; about/privacy copy |
| Demo entry points | First-run empty state → demo suggestion |

### Design constraints

- Follow `.impeccable.md` (warm dark, no neon/glass/cyberpunk)  
- `@Observable` only on UI façade; **no** duplicate session mutation  
- `Button` for actions; stable `Session.id` identity  
- Reduced motion + VoiceOver labels  

### New files UI may add

- `Design/Tokens.swift`  
- `Views/PillView.swift`, `Views/SessionDetailView.swift`  
- `Views/ApprovalSheet.swift`  

Leave **`UI_HANDOFF.md`** when done.

---

## nocturnal-qa — verify next

- `swift build` / `swift test` clean  
- Simulation path in `docs/simulation.md`  
- Fail-open exit code of forwarder  
- Setup only under `NOCTURNAL_CONFIG_ROOT`  
- Fixture decode coverage for every **implemented** event type  
- Review notes under `docs/reviews/`

---

## Packaging / env reference

| Variable | Purpose |
|----------|---------|
| `NOCTURNAL_SOCKET` | Unix socket path |
| `NOCTURNAL_APP_SUPPORT` | App Support root override |
| `NOCTURNAL_CONFIG_ROOT` | Setup CLI home sandbox |
| `NOCTURNAL_FORWARDER_DEBUG` | Forwarder stderr details |

`Scripts/package_app.sh` → **`build/Nocturnal.app`**  
Bundle id: `app.nocturnal.Nocturnal`  
Helpers: `Contents/Resources/Helpers/{nocturnal-hook-forwarder,nocturnal-setup}`

---

## Explicit non-goals (still)

- Telemetry, accounts, cloud  
- Claiming unsupported hooks work  
- Writing to real user agent configs in tests  
- Copying proprietary third-party UI
