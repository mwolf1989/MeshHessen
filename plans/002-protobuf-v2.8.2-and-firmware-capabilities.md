# Plan 002: Protobufs are on upstream v2.8.2 and a firmware-capability gate exists

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Proto MeshHessen/Generated`
> Any change there since `d470b3a` is a STOP condition (someone else may already have updated the protos).

## Status

- **Priority**: P1 (blocks plans 010–015 and parts of 017)
- **Effort**: S–M
- **Risk**: MED (regenerated code can break call sites)
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

The Mac's `.proto` files are a pre-2.8 snapshot. Everything Meshtastic firmware 2.8 added — Mesh Beacon, AEAD channels, signed ACKs, packet signature policy, "heard on current LoRa", display mirroring, lightning and soil/water telemetry, new modem presets, new hardware models — is invisible to the Mac client until the generated Swift code is regenerated. The Windows client moved to upstream v2.8.2 without code breaks.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI. Tests in `Tests/MeshHessenTests/` (Swift Testing).
- `.proto` sources: `MeshHessen/Proto/meshtastic/*.proto` (currently 11 files: admin, atak, channel, config, connection_status, device_ui, mesh, module_config, portnums, telemetry, xmodem). Generated Swift: `MeshHessen/Generated/*.pb.swift`. `MeshHessen/Proto` is excluded from the SPM target (`Package.swift`).
- Upstream: `https://github.com/meshtastic/protobufs`, commit `ffd5ad428da6db4a7ddfe62e06548718cc2603e0` (this is what the Windows client pins as v2.8.2).
- Tools present on the planner's machine: `/opt/homebrew/bin/protoc`, `/opt/homebrew/bin/protoc-gen-swift`. SwiftProtobuf runtime in the project: 1.35.0.
- Conventions: 4-space indent; never hand-edit `MeshHessen/Generated/`.

## Current state

Missing in the current protos (verify with grep before starting, e.g. `grep -c use_aead MeshHessen/Proto/meshtastic/channel.proto` → 0):
`ChannelSettings.use_aead`, `MeshPacket.ack_proof_status`, `Routing.ack_proof`, `SecurityConfig.packet_signature_policy`, `NodeInfo.heard_on_current_lora`, `DeviceMetadata.display`, `FromRadio.display_frame`/`display_palette`, `AdminMessage.set_display_mirror`/`get_display_frame_request`, `ModuleConfig.MeshBeaconConfig`, `Telemetry.soil_water_metrics`, `EnvironmentMetrics.lightning_*`, `Serial_Mode.MODBUS`, modem presets 10–16.

`MeshHessen/Services/MeshtasticProtocolService.swift` `handleFromRadio` (~538) has an exhaustive `switch fromRadio.payloadVariant` over named cases for logging — new oneof cases will make it non-exhaustive (compile error). Other exhaustive switches over generated enums exist in `MeshHessen/Models/AdminConfigurationModels.swift` and `MeshHessen/Models/MeshEnums.swift`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Proto/meshtastic/*.proto` (replace), `MeshHessen/Generated/*.pb.swift` (regenerate only), minimal compile fixes in `MeshHessen/**/*.swift` call sites, `MeshHessen/Models/FirmwareCapabilities.swift` (create), `Tests/MeshHessenTests/FirmwareCapabilitiesTests.swift` (create), `README.md` (only the protoc command line if it changes).

**Out of scope**: implementing any new 2.8 feature (those are plans 010–015). New enum/oneof cases get a neutral `default:`/log branch only. Do not add proto files the Swift code does not need beyond what upstream imports require.

## Git workflow

Branch `chore/002-protobuf-2.8.2`. Commit 1: proto sources + generated code (`chore: update protobufs to v2.8.2`). Commit 2: compile fixes. Commit 3: capability helper. Do not push.

## Steps

### Step 1: Baseline
Run `swift build` and `swift test`; note the passing test count.

**Verify**: both exit 0. If not, STOP.

### Step 2: Fetch upstream at the pinned commit
In a scratch directory outside the repo:
```
git clone https://github.com/meshtastic/protobufs.git && cd protobufs && git checkout ffd5ad428da6db4a7ddfe62e06548718cc2603e0
```
**Verify**: `grep -c use_aead meshtastic/channel.proto` → ≥ 1.

### Step 3: Replace the proto files
Copy upstream `meshtastic/<name>.proto` over each file that already exists in `MeshHessen/Proto/meshtastic/`. Then check imports: for every `import "meshtastic/….proto"` or `import "nanopb.proto"` in the copied files, make sure the imported file exists in `MeshHessen/Proto/` (copy additional upstream files as needed; `nanopb.proto` lives at the upstream repo root). Do not copy files that nothing imports.

### Step 4: Regenerate
From the repo root:
```
protoc --proto_path=MeshHessen/Proto --swift_out=MeshHessen/Generated MeshHessen/Proto/meshtastic/*.proto
```
(add `MeshHessen/Proto/nanopb.proto` to the inputs only if it was needed in step 3). Look at the current layout of `MeshHessen/Generated/` first (`ls`): if the existing files are flat (`mesh.pb.swift`) but protoc writes into a `meshtastic/` subfolder, move the generated files to match the existing layout and delete the stale ones, so there is exactly one generated file per proto.

**Verify**: `grep -c "useAead" MeshHessen/Generated/channel.pb.swift` → ≥ 1; `ls MeshHessen/Generated | sort` shows no duplicates.

### Step 5: Fix compile errors minimally
Run `swift build`. Expected classes of errors and the required fix:
- Non-exhaustive `switch` over a generated enum/oneof → add the new cases to the existing logging switch (e.g. `case .displayFrame: variant = "displayFrame"`) or a `default:` that preserves current behavior.
- Renamed/removed fields → STOP (see STOP conditions); upstream v2.8.2 is expected to be drop-in.

**Verify**: `swift build` exit 0; `swift test` passes with at least the baseline test count.

### Step 6: Firmware capability helper
Create `MeshHessen/Models/FirmwareCapabilities.swift`:
```swift
struct FirmwareVersion: Comparable, Sendable {
    let major: Int, minor: Int, patch: Int
    init?(_ string: String?)          // parses leading "^(\d+)\.(\d+)(\.(\d+))?", e.g. "2.8.1.abc123"
}
enum FirmwareCapabilities {
    static func atLeast(_ firmware: String?, _ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool  // false when unparsable
    static func supportsV28(_ firmware: String?) -> Bool { atLeast(firmware, 2, 8) }
    static func supportsEsp32Ota(_ firmware: String?) -> Bool { atLeast(firmware, 2, 7, 17) }
}
```
Windows reference: `MeshhessenClient/Services/FirmwareCaps.cs` in `/Volumes/Dock/code/Private/mesh/mh_windowsclient`.

Add `FirmwareCapabilitiesTests.swift`: `"2.8.1.abcdef"` ≥ 2.8; `"2.7.26"` < 2.8; `"2.7.17"` supports ESP32 OTA, `"2.7.16"` does not; `nil`, `""`, `"garbage"` → false.

**Verify**: `swift test --filter FirmwareCapabilities` → pass; xcodebuild Debug build → `** BUILD SUCCEEDED **`.

## Done criteria

- [ ] `grep -c "heardOnCurrentLora" MeshHessen/Generated/mesh.pb.swift` ≥ 1 and `grep -c "meshbeacon\|MeshBeacon" MeshHessen/Generated/module_config.pb.swift` ≥ 1
- [ ] `swift build`, `swift test`, xcodebuild Debug build all succeed
- [ ] No behavior change besides new enum cases being available (diff outside `Proto/` and `Generated/` is small and mechanical)
- [ ] `plans/README.md` row updated

## STOP conditions

- More than ~15 non-mechanical compile errors, or any error caused by a removed/renamed field the app actively uses.
- `protoc-gen-swift` output is incompatible with SwiftProtobuf 1.35.0 (errors mentioning `_protobuf_generated_isEqualTo` / version checks) — report the plugin version (`protoc-gen-swift --version`).
- The generated folder layout cannot be reconciled without touching `Package.swift` or `project.pbxproj`.

## Maintenance notes

- Later plans rely on these generated names (confirm exact Swift spellings with grep before using them): `useAead`, `ackProofStatus`, `packetSignaturePolicy`, `heardOnCurrentLora`, `displayFrame`, `displayPalette`, `soilWaterMetrics`, `lightningStrikeCount1H`, `meshbeacon`.
- `MeshHessen/Models/MeshEnums.swift` contains a hand-written `ModemPreset` enum that nothing references (per audit) — leave it; plan 010 deals with preset labels.
