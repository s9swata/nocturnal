# QA_REPORT — Nocturnal

**Author:** nocturnal-qa (final integration / attached-review batch)
**Date:** 2026-07-13
**Host:** macOS, Command Line Tools only (no full Xcode)
**Swift:** Apple Swift 6.2.x (`swift build` / `swift test` under CLT)
**Commit:** none (uncommitted working tree; no commit performed)

---

## Summary

| Gate | Result |
|------|--------|
| `swift test` | **PASS** — **156 tests / 13 suites** (exit 0) |
| `git diff --check` | **PASS** (exit 0) |
| `Scripts/package_app.sh` | **PASS** → `build/Nocturnal.app` |
| `file` main + helpers | **PASS** (Mach-O arm64) |
| `codesign -dv` | **PASS** (adhoc app + helpers) |
| Real `~/.codex` / `~/.claude` writes | **None** (temp dirs / packaging only) |

### Two remaining gaps (required fixes this pass)

| # | Gap | Fix |
|---|-----|-----|
| 1 | `AppModel.updateSettings` optimistic mutate + `try? save` made future-schema refusal look accepted | Load → mutate on MainActor → `settings = try await store.save(next)` only on success; surface `SettingsStoreError` on `statusMessage` |
| 2 | Flat `n.` filename prefix not disjoint (`foo` → `n.foo.json` vs literal id `n.foo`) | Canonical writes under **`sessions/records/`** and **`responses/records/`** with case-stable body encoding; read/migrate prior `n.` flat, unprefixed percent, and underscore legacy with embedded-ID checks |

---

## Per-finding validity (original 15)

| # | Finding | Valid? | Root cause | Fix / verification |
|---|---------|--------|------------|--------------------|
| 1 | Packaging non-executable Mach-O discovery | **Yes** | `find -perm -111` skipped valid Mach-O without +x | `Scripts/package_app.sh`: enumerate `-type f`, filter `file` for `Mach-O` in lipo + sign |
| 2 | Single-arch error text always multi-arch | **Yes** | Unconditional second stderr line | Gate multi-arch line on `${#ARCH_LIST[@]} -gt 1` |
| 3 | JSON control escaping | **Yes** | Slash/quote-only escape invalid for controls | `HookInstaller.escapeJSONStringContents` via `JSONSerialization` + fallback; tests with `\n`/`\t`/quotes |
| 4 | Stale session ordering | **Yes** | Stale apply still promoted list order | `SessionStore.upsert(..., promoteToFront: !isStaleEvent)`; `staleEventDoesNotPromoteSessionOrdering` |
| 5 | Future settings persistence | **Yes** | Save could overwrite / UI optimistic | `SettingsStore` refuses `newerSchemaOnDisk`; `update`/`save` return stamped value; **AppModel fixed** |
| 6 | Safe `v` normalization | **Yes** | Truncating Double→Int could trap | `exactIntValue` / exact Int64 path only; oversized/fractional → current schema |
| 7 | Settings field assertion | **Yes** (test gap) | `settingsNeverDowngradeSchema99` decoded `showFloatingPill=false` but did not assert it (and other fields) | Added `#expect(decoded.showFloatingPill == false)` (+ `soundEnabled` / `maxVisibleSessions`); **no production behavior change** |
| 8 | `1e12` timestamp boundary | **Yes** | `>` left exact 1e12 as seconds | `>= 1_000_000_000_000` → ms; epoch boundary test |
| 9 | `exactIntegerString` contract | **Yes** | `String(format:)` fallback imprecise | Returns `nil` outside exact Int64; tests for 1e20 / non-integral |
| 10 | Socket shutdown | **Yes** | `close` alone could leave blocked read | `Darwin.shutdown(fd, SHUT_RDWR)` before close; `stopUnblocksIdleClientReadViaShutdown` |
| 11 | Empty CLI values + safe timeout cap | **Yes** | Empty token accepted; huge timeout → Int32 trap risk | Empty → missingValue; timeout clamp to `Int32.max/1000`; CLI + options tests |
| 12 | Env-independent hook test + rename | **Yes** | Assertions depended on host `/Users` paths | Quote-value equality; `sidecarBacksUpInvalidFileBeforeOverwrite` rename |
| 13 | `deleteAll` special files | **Yes** | Could unlink FIFO/symlink | Regular non-symlink files only; `deleteAllSkipsSymlinksFifosAndSockets` |
| 14 | Collision-free persistence namespace | **Yes** (prior `n.` incomplete) | Flat `n.` not disjoint from arbitrary ids | **`records/` subdirectory** + case-stable body; migrate prior layouts; regression tests |
| 15 | Hook forwarder envelope/socket size | **Yes** | Normalize can exceed socket frame | Reject oversized normalized payload before send; oversized + deliverable tests |

---

## Test results (exact)

```text
$ swift test
…
✔ Test run with 156 tests in 13 suites passed after 0.553 seconds.
```

```text
$ git diff --check
# (no output, exit 0)
```

### New / updated coverage (this integration pass)

| Area | Tests |
|------|--------|
| `records/` vs prior `n.` / legacy | `canonicalFooIsDisjointFromLiteralNDotFoo`, `fooAndNDotFooPersistIndependently`, `loadMigratesPriorNPrefixedFlatFile…` |
| `a/b` vs literal `a%2Fb` | `slashIdIsDisjointFromLiteralPercentEncodedId` (canonical + coexistence) |
| ASCII case variants | `asciiCaseVariantsRemainDistinctOnCaseInsensitivePaths` |
| Settings refuse / no cache poison | `settingsUpdateRefusesNewerSchemaWithoutCachePoison` |
| Settings field assertions (schema 99) | `settingsNeverDowngradeSchema99` asserts `showFloatingPill == false` (test gap only) |
| Stale order (non-tautological title) | `staleEventDoesNotPromoteSessionOrdering` |
| Packaging / socket / CLI / JSON / shutdown | suites from attached review batch (all green in 156-run) |

App-level UI (`AppModel`) has no automated runner under CLT; core seam is `SettingsStore.load` → `save` returning stamped value only on success. Production wiring in `Sources/Nocturnal/AppModel.swift`.

---

## Coverage map

| Required area | Suite / tests | Status |
|---------------|---------------|--------|
| Event decoding (Codex/Claude) | `EventDecodingTests` | Pass |
| Unknown raw metadata | decoder + `SessionStoreTests` | Pass |
| State transitions | lifecycle / approval / question | Pass |
| Socket bridge | `SocketBridgeTests` (incl. shutdown) | Pass |
| Persistence load/save/migrate | `PersistenceTests` | Pass |
| Path namespace collisions | `records/` + prior + legacy regressions | Pass |
| Settings future schema | load/save/update refuse | Pass |
| Hook install temp-only | `HookInstallerTests` | Pass |
| Response routing subdirs | `ResponseRoutingTests` | Pass |
| Fail-open forwarder frame limit | `HookForwarderTests` | Pass |
| CLI empty values + timeout | `CLIParsingTests` | Pass |
| `deleteAll` special nodes | Persistence | Pass |
| Packaging Mach-O discovery | script + ad-hoc shell earlier; package green | Pass |

### Gaps (not automated)

| Gap | Notes |
|-----|--------|
| SwiftUI / AppKit UI | No UI test runner under CLT; `AppModel` settings path verified by code review + core store tests |
| Live Gatekeeper / notarization | Adhoc only |
| Multi-arch universal lipo with real frameworks | No third-party frameworks in tree |

---

## Packaging verification

### Command

```bash
ARCHES=$(uname -m) Scripts/package_app.sh
```

Exit **0**. Output path: `build/Nocturnal.app`.

### `file`

```text
build/Nocturnal.app/Contents/MacOS/Nocturnal:                            Mach-O 64-bit executable arm64
build/Nocturnal.app/Contents/Resources/Helpers/nocturnal-hook-forwarder: Mach-O 64-bit executable arm64
build/Nocturnal.app/Contents/Resources/Helpers/nocturnal-setup:          Mach-O 64-bit executable arm64
```

### `codesign -dv build/Nocturnal.app`

```text
Executable=…/build/Nocturnal.app/Contents/MacOS/Nocturnal
Identifier=app.nocturnal.Nocturnal
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 … flags=0x2(adhoc) …
Signature=adhoc
```

Helpers adhoc-signed under `Contents/Resources/Helpers/` and `Contents/MacOS/`.

---

## Key code changes (this pass)

| File | Change |
|------|--------|
| `Sources/Nocturnal/AppModel.swift` | Settings: persist-then-publish; errors on `statusMessage` |
| `Sources/NocturnalCore/Settings/AppSettings.swift` | `save` returns stamped value; `update` `@Sendable`; future-schema refuse unchanged (no maxVisibleSessions decode clamp) |
| `Sources/NocturnalCore/Persistence/PersistencePaths.swift` | Canonical `records/` layout; prior `n.` + unprefixed + legacy candidates |
| `Sources/NocturnalCore/Persistence/SessionPersistence.swift` | loadAll/deleteAll cover records/; migrate never overwrites foreign id |
| `Sources/NocturnalCore/Transport/ResponseTransport.swift` | Docs for `responses/records/` |
| Tests + `CORE_HANDOFF.md` + `docs/HOOK_SCHEMAS.md` | Align with layout + settings contract |

---

## Commands reference

```bash
swift build
swift test
Scripts/package_app.sh
file build/Nocturnal.app/Contents/MacOS/Nocturnal
codesign -dv --verbose=4 build/Nocturnal.app
git diff --check
```

---

## Known limitations

1. **CLT / Xcode:** Swift Testing via SPM; no system XCTest without Xcode.
2. **UI tests:** None automated for AppKit/SwiftUI surfaces.
3. **Socket path length:** Prefer short paths under `/tmp` for sim/tests.
4. **Adhoc signing only** — not notarized.
5. **Flat prior/legacy candidate overlap** (e.g. prior `a/b` vs legacy literal `a%2Fb` → same `a%2Fb.json`) remains possible; **embedded session id** remains authoritative and is covered by tests.

---

## Done criteria

1. Automated tests run and pass (`swift test`) — **yes (156 / 13)**
2. Package script produces `build/Nocturnal.app` — **yes**
3. `file` + `codesign` verification recorded — **yes**
4. Both remaining gaps fixed (settings UI + disjoint path namespace) — **yes**
5. All 15 findings inspected; incomplete pieces fixed — **yes**
6. `git diff --check` clean — **yes**
7. `QA_REPORT.md` complete with exact counts — **yes**
8. No commit performed — **yes**
