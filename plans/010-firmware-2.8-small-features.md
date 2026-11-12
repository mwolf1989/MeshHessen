# Plan 010: Firmware 2.8 indicators and settings — signed ACKs, signature policy, heard-on-radio flag, AEAD badge, new presets

> **Executor instructions**: Follow this plan step by step. Steps are independent — commit after each. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Models MeshHessen/Views/DeviceConfigView.swift MeshHessen/Views/SharedMessageViews.swift MeshHessen/Views/ChannelsTabView.swift MeshHessen/Views/NodeListView.swift MeshHessen/Views/NodesTabView.swift`
> Plan 002 is expected to have changed `MeshHessen/Generated` and a few call sites; that is fine.

## Status

- **Priority**: P2
- **Effort**: M (five S items)
- **Risk**: LOW
- **Depends on**: plans/002-protobuf-v2.8.2-and-firmware-capabilities.md (hard requirement)
- **Category**: direction (feature parity with Windows 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows 1.7.2 surfaces five firmware-2.8 capabilities that only need a field read/write once the protobufs are current: a shield on delivery ticks when the ACK was cryptographically verified (and a red warning when the signature is invalid), a packet-signature-policy picker, a "heard directly on the current LoRa slot" marker, a badge on AEAD-encrypted channels, and the complete modem-preset / serial-mode lists with readable labels.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Models/MessageItem.cs` (~145–172, `AckProofStatus`), `MeshhessenClient/Models/NodeInfo.cs` (~54–58), `MeshhessenClient/Models/ChannelInfo.cs`, `MeshhessenClient/NodeConfigWindow.xaml` (~368–385 presets, ~878–892 serial modes, ~952–957 signature policy), `MeshhessenClient/Services/MeshtasticProtocolService.cs` (~2026, ~2629, ~2810).
- `FirmwareCapabilities.supportsV28(_:)` exists after plan 002 (`MeshHessen/Models/FirmwareCapabilities.swift`).
- UI strings: English in code + German translation in `MeshHessen/Localizable.xcstrings` (only add keys).
- Generated Swift names must be confirmed by grep in `MeshHessen/Generated/` before use (expected: `ackProofStatus`, `packetSignaturePolicy`, `heardOnCurrentLora`, `useAead`).

## Current state

- `MeshHessen/Models/MessageItem.swift` (~72): `MessageDeliveryState` = none / pending / acknowledged / failed. Delivery updates come from `handleRoutingPacket` in `MeshHessen/Services/MeshtasticProtocolService.swift` (~941). Ticks are rendered in `MeshHessen/Views/SharedMessageViews.swift` (~42–62).
- `SecurityConfigurationForm` (`MeshHessen/Views/DeviceConfigView.swift` ~1474) has sections "Node keys" and "Administration"; it binds directly to `Meshtastic_Config.SecurityConfig`, so local and remote admin share it.
- `MeshHessen/Models/NodeInfo.swift`: heuristic `isDirectRF` (~203) = `hopsAway == 0 && !viaMqtt && lastDirectHeard > 0`. Device snapshots are handled in `handleNodeInfo(_:)` (~1148); RF user packets in `handleNodeInfoPacket` (~1121).
- `MeshHessen/Models/ChannelInfo.swift`: `id, name, psk, role, uplinkEnabled, downlinkEnabled`; built in `channelInfo(from:)` (`MeshtasticProtocolService.swift` ~1233); listed in `MeshHessen/Views/ChannelsTabView.swift`.
- `LoRaConfigurationForm` (~1413) and `SerialConfigurationForm` (~1768) in `DeviceConfigView.swift` use `ModemPreset.allCases` / `Serial_Mode.allCases` with raw enum labels.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Firmware28` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Models/MessageItem.swift`, `NodeInfo.swift`, `ChannelInfo.swift`, `MeshHessen/Services/MeshtasticProtocolService.swift` (three small touch points), the five view files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/Firmware28FeatureTests.swift` (create).

**Out of scope**: AEAD encryption/decryption (plan 015), Mesh Beacon and module forms (plan 011), Core Data schema changes (ack proof is kept in memory only), any enforcement of signature policy (firmware does that).

## Git workflow

Branch `feat/010-firmware-2.8-small`; one conventional commit per step. Do not push.

## Steps

### Step 1: Signed-ACK indicator
- Add `enum AckProof: Int, Sendable { case absent = 0, valid = 1, invalid = 2, noKey = 3 }` and `var ackProof: AckProof = .absent` to `MessageItem` (separate property — do not add cases to `MessageDeliveryState`).
- In `handleRoutingPacket`, when a message is marked acknowledged, also set `ackProof` from the **packet's** `ackProofStatus` (the MeshPacket carrying the routing ACK). Follow how the function currently locates and updates the message.
- In `SharedMessageViews.swift` next to the acknowledged ticks: `.valid` → append a small `checkmark.shield` icon, `.help("Receipt cryptographically verified")`; `.invalid` → red `exclamationmark.shield`, `.help("Receipt signature INVALID — possibly forged")`. `.absent`/`.noKey` → unchanged. Never change the delivery state because of the proof ("flag, never block").

### Step 2: Packet signature policy
In `SecurityConfigurationForm` add a section "Packet signatures" with a `Picker` bound to `config.packetSignaturePolicy` (cases Compatible / Balanced / Strict — use the generated enum's cases and give them these labels) and a caption: "Strict hides nodes running older firmware. Enforcement is done by the device (firmware 2.8+)."

### Step 3: Heard on current LoRa
- `NodeInfo`: add `var heardOnCurrentLora: Bool?` (nil = unknown).
- `handleNodeInfo(_:)` (device snapshot path only): set it from the generated field **only** when `FirmwareCapabilities.supportsV28(appState?.myNodeInfo?.firmwareVersion)`; otherwise leave nil. Do not touch it in `handleNodeInfoPacket`. In `AppState.upsertNode` copy it only under `refreshNodeDatabaseFlags` (same rule as `isFavorite`).
- Show a small `antenna.radiowaves.left.and.right` icon with `.help("Heard directly by this radio on the current LoRa slot")` in the node rows of `NodeListView.swift` and `NodesTabView.swift` when the value is `true`.

### Step 4: AEAD badge
- `ChannelInfo`: add `var useAead: Bool = false`; fill it in `channelInfo(from:)` from `channel.settings.useAead`. Fix every other `ChannelInfo(...)` initialiser call that the compiler flags (default value should make this unnecessary).
- `ChannelsTabView.swift`: show `Image(systemName: "shield.lefthalf.filled")` with `.help("AEAD-encrypted channel (firmware 2.8, experimental)")` for such channels.

### Step 5: Preset and serial-mode labels
Add a file-private helper in `DeviceConfigView.swift` (or an extension in `MeshEnums.swift`) mapping the generated `ModemPreset` cases to labels: Long Fast, Long Slow (deprecated), Very Long Slow (deprecated), Medium Slow, Medium Fast, Short Slow, Short Fast, Long Moderate, Short Turbo, Long Turbo, Lite Fast, Lite Slow, Narrow Fast, Narrow Slow, Tiny Fast, Tiny Slow, Medium Turbo; unknown cases fall back to `String(describing:)`. Use it in `LoRaConfigurationForm`'s picker. Do the same for `Serial_Mode` (Default, Simple, Proto, Text message, NMEA, CalTopo, WS85 weather station, VE.Direct (Victron), MS config, Log, Log text, Modbus). Use a `switch` with a `default:` so future enum cases compile.

**Verify (each step)**: `swift build` exit 0; after step 5 the app build succeeds.

## Test plan

`Firmware28FeatureTests.swift`:
- `channelInfo(from:)` is private — test through whatever internal entry point existing tests use for channels (see `ChannelAdministrationTests.swift`); if none, make a `static func` variant internal. A channel with `settings.useAead = true` yields `ChannelInfo.useAead == true`.
- `AckProof(rawValue:)` round-trips 0–3.
- Preset label helper: `.longSlow` label contains "deprecated"; every case in `allCases` yields a non-empty label.
- `AppState.upsertNode`: `heardOnCurrentLora` is not overwritten by an upsert without `refreshNodeDatabaseFlags`.

**Verify**: `swift test --filter Firmware28` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 including the new suite; xcodebuild Debug build succeeds
- [ ] `grep -rn "packetSignaturePolicy" MeshHessen/Views/DeviceConfigView.swift` ≥ 1 match
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- Any of the four generated fields is missing in `MeshHessen/Generated/` (plan 002 not done or done against a different commit).
- `handleRoutingPacket` still hand-parses the routing payload and has no access to the `Meshtastic_MeshPacket` — report instead of restructuring it.

## Maintenance notes

- All indicators appear only with a firmware-2.8 device; with older firmware nothing changes. Not verified on hardware by the planner.
- The `ackProof` flag is not persisted; after a restart acknowledged messages show plain ticks. Persisting needs a Core Data model version — deliberately deferred.
