# Plan 011: Native forms for six module configs and the new Mesh Beacon module

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/DeviceConfigView.swift MeshHessen/Models/AdminConfigurationModels.swift MeshHessen/Services/MeshtasticProtocolService.swift`

## Status

- **Priority**: P2
- **Effort**: M–L
- **Risk**: LOW–MED
- **Depends on**: plans/002-protobuf-v2.8.2-and-firmware-capabilities.md (hard, for Mesh Beacon and the firmware gate); plans/001 (for `UTF8Limits`)
- **Category**: direction (feature parity with Windows 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Six module configurations (Audio, Remote Hardware, Ambient Lighting, Detection Sensor, Paxcounter, TAK) can be loaded and saved by the Mac client but are only editable as raw protobuf JSON. Windows 1.7.2 has proper forms for them. The firmware-2.8 "Mesh Beacon" module does not exist on the Mac at all. Requesting TAK/Mesh Beacon from firmware older than 2.8 also costs an 8-second timeout each.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/NodeConfigWindow.xaml.cs` (load ~729–845, save ~1486–1576, validation ~1172), `MeshhessenClient/NodeConfigWindow.xaml` (~994–1012), `MeshhessenClient/RemoteAdminWindow.xaml.cs` (~443–461, ~944–972).
- The Mac admin UI (`NodeAdministrationView` in `DeviceConfigView.swift`) is shared by local config and remote admin: a `draft: MeshConfigurationSnapshot` is edited through bindings; saving diffs `draft` against `original` and writes whole protos in one edit transaction — so "clone and update" is automatic. Do not build a second save path.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

`MeshHessen/Views/DeviceConfigView.swift` `typedModuleEditor` (~474):
```swift
case .serial:
    SerialConfigurationForm(config: $draft.serial)
default:
    ContentUnavailableView("Advanced configuration", systemImage: "curlybraces",
        description: Text("This module remains fully editable in the advanced protobuf JSON editor below."))
```
Form pattern to copy — `SecurityConfigurationForm` (~1474): `private struct …: View { @Binding var config: Meshtastic_Config.SecurityConfig; var body: some View { Form { Section("…") { Toggle(…, isOn: $config.x) … } }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity) } }`. Look at `SerialConfigurationForm` (~1768) for pickers over generated enums and numeric fields.

`MeshHessen/Models/AdminConfigurationModels.swift`: `enum MeshModuleConfigCategory` (~65) lists mqtt, serial, externalNotification, storeForward, rangeTest, telemetry, cannedMessage, audio, remoteHardware, neighborInfo, ambientLighting, detectionSensor, paxcounter, statusMessage, trafficManagement, tak — with `title`, a request-type mapping and snapshot apply/extract switches further down; `MeshConfigurationSnapshot` (~375) has one stored property per module (e.g. `draft.serial`).

`MeshHessen/Services/MeshtasticProtocolService.swift` `requestCompleteConfiguration` (~1990) requests every category in the selection with a per-item timeout.

Field lists (confirm Swift names in `MeshHessen/Generated/module_config.pb.swift`):
- **Audio**: codec2 enabled, bitrate (enum), PTT pin, I2S WS/SD/DIN/SCK pins.
- **Remote Hardware**: enabled, allow undefined pin access (show a security warning label).
- **Ambient Lighting**: LED state, current, red, green, blue (0–255).
- **Detection Sensor**: enabled, name (max **19 UTF-8 bytes**), monitor pin, trigger type (enum), use pull-up, send bell, minimum broadcast secs, state broadcast secs.
- **Paxcounter**: enabled, update interval (s), Wi-Fi RSSI threshold, BLE RSSI threshold.
- **TAK** (FW ≥ 2.8): team, role (enums from `atak.pb.swift`).
- **Mesh Beacon** (FW ≥ 2.8, ModuleConfigType 16): `flags` bitmask 1 = listen, 2 = broadcast, 4 = legacy split; `broadcast_message` (max **60 UTF-8 bytes**); `broadcast_interval_secs` (minimum 3600, default 3600); optional `broadcast_offer_preset`; optional `broadcast_offer_frequency_slot`; optional `broadcast_offer_channel` (a `ChannelSettings` with name + PSK copied from one of the device's channels); `broadcast_targets` must be left untouched.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter AdminConfiguration` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Views/DeviceConfigView.swift` (new forms may go into a new file `MeshHessen/Views/ModuleConfigurationForms.swift` — then make the shared field helpers they need `internal` instead of `private`), `MeshHessen/Models/AdminConfigurationModels.swift`, `requestCompleteConfiguration` in `MeshtasticProtocolService.swift` (firmware gate only), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/AdminConfigurationParityTests.swift`.

**Out of scope**: StatusMessage (plan 012), TrafficManagement, the JSON editor, save/diff logic.

## Git workflow

Branch `feat/011-module-forms`; commit per form group. Do not push.

## Steps

### Step 1: Six forms
Add `AudioConfigurationForm`, `RemoteHardwareConfigurationForm`, `AmbientLightingConfigurationForm`, `DetectionSensorConfigurationForm`, `PaxcounterConfigurationForm`, `TAKConfigurationForm` following the pattern above, bound to the matching `draft.<module>` property, and add the six `case`s to `typedModuleEditor`. Clamp the detection-sensor name with `UTF8Limits.clamp(_, maxBytes: 19)` on change. The JSON editor below the form stays.

**Verify**: app build succeeds; `grep -c "ConfigurationForm(config: \$draft" MeshHessen/Views/DeviceConfigView.swift` increased by 6.

### Step 2: Mesh Beacon in the model
In `AdminConfigurationModels.swift` add `case meshBeacon` to `MeshModuleConfigCategory` and extend **every** switch over the enum in that file (title "Mesh Beacon", request type = the generated `.meshbeaconConfig` case, apply-from-`ModuleConfig`, build-`ModuleConfig`, loaded flags, diff). Add `var meshBeacon` + loaded flag to `MeshConfigurationSnapshot` mirroring how `tak` is handled — search the file for `tak` and replicate each occurrence.

**Verify**: `swift build` exit 0 (the compiler lists any switch you missed).

### Step 3: Firmware gate
Add `var requiresFirmwareV28: Bool` to `MeshModuleConfigCategory` (true for `.tak`, `.meshBeacon`). In `requestCompleteConfiguration`, skip such categories when the **target's** firmware is known and below 2.8 (local: `appState.myNodeInfo?.firmwareVersion`; remote: metadata from the snapshot if already loaded, otherwise do not skip). In the editor show for skipped categories: "Requires firmware 2.8 or newer."

### Step 4: Mesh Beacon form
`MeshBeaconConfigurationForm(config: $draft.meshBeacon, channels: draft.channels)`:
- Three toggles bound to the `flags` bits.
- Message `TextField` with live "n/60 bytes" caption, clamped via `UTF8Limits.clamp(_, maxBytes: 60)`.
- Interval stepper/field, enforced `>= 3600`.
- Offer preset: picker "Same as device" (clears the optional) + all modem presets (use the label helper from plan 010 if present).
- Offer frequency slot: integer field; 0/empty clears the optional.
- Offer channel: picker "None" (clear) / "Unchanged" (leave as loaded) / one entry per active device channel (copies `name` and `psk` into `broadcastOfferChannel`); show a warning when a channel with a non-default PSK is offered: "The channel key is broadcast to everyone who hears the beacon."
- Warning label: "Broadcasting on a different modem preset retunes the radio; the node does not receive on its primary preset meanwhile. Not suitable for routers."

**Verify**: app build succeeds.

## Test plan

Extend `AdminConfigurationParityTests.swift` (see existing tests there for building snapshots):
- A snapshot whose `meshBeacon` differs from the original yields a diff containing the mesh-beacon category; unchanged → not in the diff.
- `MeshModuleConfigCategory.allCases` each have a non-empty title; `.tak` and `.meshBeacon` require firmware 2.8, `.serial` does not.
- Flags bitmask helper (if you add one): listen+broadcast == 3.

**Verify**: `swift test` → all pass.

## Done criteria

- [ ] `typedModuleEditor`'s `default:` branch is reached only by `.statusMessage` and `.trafficManagement`
- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The generated code has no Mesh Beacon config (plan 002 missing).
- `MeshConfigurationSnapshot` is not extensible by replicating the `tak` handling (e.g. it is generated or uses reflection).
- A generated field named above does not exist — list the actual fields of that message and stop rather than guessing semantics.

## Maintenance notes

- Not verified against hardware. Reviewer: load/save each new form against a real node and confirm unrelated fields are unchanged (compare JSON before/after).
- Remote admin gets all forms automatically because it reuses `NodeAdministrationView`.
