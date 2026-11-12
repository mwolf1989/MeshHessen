# Plan 009: Offline map mode uses the Mesh Hessen servers; NodeDB reset, remote-admin errors and quick config match Windows

> **Executor instructions**: Follow this plan step by step. Steps are independent — commit after each. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/OfflineMapManagerView.swift MeshHessen/Views/MapView.swift MeshHessen/Views/DeviceConfigView.swift MeshHessen/Models/AdminConfigurationModels.swift MeshHessen/Models/MeshEnums.swift MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Views/TDeckWizardView.swift`

## Status

- **Priority**: P2
- **Effort**: M (five S items)
- **Risk**: LOW–MED (step 5 writes device config)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Five small divergences from the Windows client (1.6.2.3 – 1.7.0): in "offline" map mode the Mac downloads tiles from the user-editable *custom* URLs instead of the Mesh Hessen tile server; the NodeDB reset offers no choice about favourites; a rejected remote-admin command shows the raw routing error without telling the user what to do; remote-admin packets rely on the firmware to fill in the hop limit; and the "Mesh Hessen quick configuration" does not set the MQTT flags and never verifies the result.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing). Baseline: `swift test` → 261 pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/MainWindow.Map.cs` (`GetActiveTileUrl`, ~42–60), `MeshhessenClient/NodeDbResetDialog.xaml.cs`, `MeshhessenClient/RemoteAdminWindow.xaml.cs` (~126–153), `MeshhessenClient/MainWindow.xaml.cs` (~1757–1947, `ApplyMeshHessenProfileAsync`).
- UI strings: English in code + German translation in `MeshHessen/Localizable.xcstrings` (it has an unrelated uncommitted change — only add keys).

## Current state (excerpts at `d470b3a`)

1. `Views/OfflineMapManagerView.swift` (~28):
   ```swift
   case .meshHessen:
       return .init(source: source, urlTemplate: source.meshHessenRasterURLTemplate)
   case .publicOpenStreetMap:
       return .init(source: .osm, urlTemplate: settings.publicOSMTileURL)
   case .custom, .offline:
       ... template = settings.osmTileURL / topographicTileURL / darkTileURL
   ```
   `Views/MapView.swift` (~453) has the same `case .custom, .offline:` → `customRasterTemplate`, and `if mode == .meshHessen { vectorStyleURL = source.meshHessenVectorStyleURL } else { …custom style URLs… }`.
2. `Views/DeviceConfigView.swift` (~594): `Button("Reset node database (preserve favorites)") { confirm(.resetNodeDatabase(preserveFavorites: true), …) }`. `Models/AdminConfigurationModels.swift` (~646): `case .resetNodeDatabase(let preserveFavorites): message.nodedbReset = preserveFavorites`.
3. Remote-admin failures surface as `DeviceConfigError.routingFailed` with a `RoutingError` value (`Models/MeshEnums.swift`); no remediation text.
4. `Services/MeshtasticProtocolService.swift` `makeAdminMeshPacket` (~3557) sets `wantAck = true`, `priority = .reliable` but not `hopLimit`/`hopStart`.
5. `applyMeshHessenQuickConfiguration` (~2298):
   ```swift
   updated.lora.usePreset = true
   updated.lora.modemPreset = .shortSlow
   if updated.lora.region == .unset { updated.lora.region = .eu868 }
   updated.lora.hopLimit = 7
   ... add Mesh Hessen channel to first free slot ...
   return try await saveCompleteConfiguration(updated, replacing: original, to: target, timeout: timeout)
   ```
6. `Views/TDeckWizardView.swift` (~172): "Offline packages in this assistant are limited to Germany." (coverage is Germany, Austria, Switzerland).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the seven files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/MapOfflineParityTests.swift`, `Tests/MeshHessenTests/AdminConfigurationParityTests.swift`.

**Out of scope**: tile cache internals (`CachingTileOverlay`, `VectorTileCacheService`), the settings UI for custom URLs, the "client mirror reset" that already happens automatically after a NodeDB reset.

## Git workflow

Branch `fix/009-map-admin-polish`; one conventional commit per step. Do not push.

## Steps

### Step 1: Offline mode → Mesh Hessen URLs
In both switch statements move `.offline` to the `.meshHessen` branch (`case .meshHessen, .offline:`), and in `MapView.swift` change the vector style condition to `mode == .meshHessen || mode == .offline`. Custom URLs must apply only in `.custom`.

**Verify**: `swift build`; extend `MapOfflineParityTests.swift` with a test that the descriptor for `.offline` equals the one for `.meshHessen` if the descriptor logic is reachable from tests (it lives in views — if it is not reachable, extract the mode→template mapping into a small `static func` on the settings/model type first, then test it).

### Step 2: NodeDB reset choice
Replace the single button by one that opens a confirmation sheet with a toggle "Also remove favorites" (default off). Confirm sends `.resetNodeDatabase(preserveFavorites: !removeFavorites)`. Keep the existing confirmation flow (`confirm(_:named:)`) if it can carry the choice; otherwise present a small dedicated `.sheet`.

### Step 3: Remote-admin hints
Add to `RoutingError` in `MeshEnums.swift` a computed `var adminHint: String?`:
- admin public key unauthorized → "The remote node does not list this node's public key as an admin key."
- PKI failed / PKI unknown public key → "The remote node's public key is unknown or outdated. Request its node info and try again."
- max retransmit / no route → "The remote node did not answer. It may be out of range or offline."
(Use the exact case names of the Swift enum — read it first.) Append the hint to `DeviceConfigError.routingFailed`'s `errorDescription`.

**Verify**: add a test in `AdminConfigurationParityTests.swift` that each of those cases has a non-nil hint and that an unrelated case returns nil.

### Step 4: Explicit hop limit on admin packets
In `makeAdminMeshPacket`, for remote targets (`fromNodeID != toNodeID`) set `packet.hopLimit = 7` and `packet.hopStart = 7`.

### Step 5: Quick configuration parity
In `applyMeshHessenQuickConfiguration`:
- also set `updated.lora.txEnabled = true`, `updated.lora.configOkToMqtt = true`, `updated.lora.ignoreMqtt = false`, and force `updated.lora.region = .eu868` (Windows forces it; the profile is only valid for EU868) — confirm the Swift property names in `MeshHessen/Generated/config.pb.swift`.
- After `saveCompleteConfiguration` returns, add a verification function `static func meshHessenProfileIssues(in snapshot: MeshConfigurationSnapshot) -> [String]` returning human-readable unmet items (preset, region, hop limit, okToMqtt, ignoreMqtt, channel present). Expose a second async function `verifyMeshHessenQuickConfiguration(target:)` that re-reads the configuration (`requestCompleteConfiguration`) and returns the issues. Do **not** block on the device reboot inside the apply function.
- In `DeviceConfigView.swift` (quick-config action ~732): after the reload that already happens, call the verify function and show the issues (or "Mesh Hessen profile verified") in the existing `statusMessage`.

**Verify**: unit-test `meshHessenProfileIssues` with a compliant and a non-compliant snapshot in `AdminConfigurationParityTests.swift`.

### Step 6: DACH text
Change the T-Deck string to "Offline packages in this assistant are limited to Germany, Austria and Switzerland." and update the German translation.

**Verify (all)**: `swift test` → all pass; xcodebuild Debug build succeeds.

## Done criteria

- [ ] `grep -n "case .custom, .offline" MeshHessen/Views` → no matches
- [ ] `swift test` exits 0 with the new tests; xcodebuild Debug build succeeds
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `MeshConfigurationSnapshot` cannot be constructed in tests.
- The LoRa config has no `configOkToMqtt`/`ignoreMqtt` in the generated code.
- Forcing EU868 contradicts an explicit comment or test in the repo ("EU_868 when unset" is the current documented behaviour — if a test asserts it, change the test and say so in your report; if a maintainer comment forbids it, STOP).

## Maintenance notes

- Step 5 changes radio settings on a real device; it was not verified on hardware by the planner.
- Windows writes LoRa twice around the channel write to survive the firmware's EU868 coercion of `ignore_mqtt`; the Mac writes through a diff in one transaction. If the verify step reports `ignoreMqtt` still set after reboot, the follow-up is a second LoRa write — deliberately not included here.
