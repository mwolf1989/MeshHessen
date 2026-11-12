# Plan 007: The Virtual Node answers the Android app's two-stage config handshake

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/VirtualNodeService.swift Tests/MeshHessenTests/VirtualNodeServiceTests.swift`

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

The Virtual Node lets phone apps connect to the Mac client over TCP as if it were a radio. Current Meshtastic Android versions fetch configuration in two stages using special `want_config_id` nonces: `69420` = "config only, no node database", `69421` = "node database only". The Mac always replays everything, so the Android app receives `my_info` twice, concludes the node rebooted and loops on reconnect. Windows fixed this in 1.6.4.2. Windows also synthesises the own-node `NodeInfo` frame if the radio never sent one (1.6.0.1).

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift; tests in `Tests/MeshHessenTests/` (Swift Testing: `import Testing`, `@testable import MeshHessen`). Baseline: `swift test` → 261 pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/VirtualNodeService.cs` lines ~249–319, `MeshhessenClient.Tests/VirtualNodeSnapshotTests.cs`.

## Current state

`MeshHessen/Services/VirtualNodeService.swift`, `VirtualNodeReplayCache` (struct at the top of the file) keeps `myInfoFrame`, `metadataFrame`, `channelFrames`, `configFrames`, `moduleConfigFrames`, `nodeFrames` (already framed `Data`) and:
```swift
func replayFrames(wantConfigID: UInt32) throws -> [Data] {
    var frames: [Data] = []
    if let myInfoFrame { frames.append(myInfoFrame) }
    if let metadataFrame { frames.append(metadataFrame) }
    frames.append(contentsOf: channelFrames.sorted { $0.key < $1.key }.map(\.value))
    frames.append(contentsOf: configFrames.sorted { $0.key < $1.key }.map(\.value))
    frames.append(contentsOf: moduleConfigFrames.sorted { $0.key < $1.key }.map(\.value))
    frames.append(contentsOf: nodeFrames.sorted { $0.key < $1.key }.map(\.value))

    var completion = Meshtastic_FromRadio()
    completion.configCompleteID = wantConfigID
    frames.append(try MeshtasticStreamFrameCodec.frame(completion.serializedData()))
    return frames
}
```
Existing tests: `Tests/MeshHessenTests/VirtualNodeServiceTests.swift`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter VirtualNode` | all pass |
| All tests | `swift test` | all pass |

## Scope

**In scope**: `MeshHessen/Services/VirtualNodeService.swift`, `Tests/MeshHessenTests/VirtualNodeServiceTests.swift`.

**Out of scope**: transport/server code, kiosk admin blocking, `MeshtasticProtocolService`.

## Git workflow

Branch `fix/007-virtual-node-two-stage`. Conventional commits. Do not push.

## Steps

### Step 1: Branch on the nonce
In `VirtualNodeReplayCache` add
```swift
static let configOnlyNonce: UInt32 = 69420
static let nodesOnlyNonce: UInt32 = 69421
```
and change `replayFrames(wantConfigID:)`:
- `69420` → my_info, metadata, configs, module configs, channels — **no** node frames (use the Windows order: my_info, metadata, config, moduleConfig, channel).
- `69421` → node frames only (no my_info, metadata, config, channels).
- any other value → current full dump, unchanged.
- Always end with `config_complete_id` echoing the client's nonce.

**Verify**: `swift build` exit 0.

### Step 2: Synthesise the own-node frame when missing
Add an optional parameter `ownNodeFallback: Meshtastic_NodeInfo? = nil` to `replayFrames`. When node frames are part of the reply (full dump or `69421`), `myInfoFrame` is known, and `nodeFrames` has no entry for the own node number, append a frame built from `ownNodeFallback` (`FromRadio.nodeInfo`, framed with `MeshtasticStreamFrameCodec.frame`). The own node number is inside `myInfoFrame`; if the cache does not already keep it as a number, store `myNodeNum` when the my_info frame is ingested (see the `ingest…` function that fills `myInfoFrame`). At the call site of `replayFrames`, pass a `Meshtastic_NodeInfo` built from `appState.myNodeInfo` (num, `user.id` = `"!%08x"`, `user.longName`, `user.shortName`) if that information is reachable there; if it is not reachable without new plumbing through more than one type, pass nil and note it in your report.

### Step 3: Tests
Add to `VirtualNodeServiceTests.swift` (reuse the helpers that build a populated cache in existing tests):
- nonce 69420 → frames decode to: 1 my_info, metadata (if present), all configs/modules/channels, **0** nodeInfo, last frame `configCompleteID == 69420`.
- nonce 69421 → only nodeInfo frames + `configCompleteID == 69421`; no my_info.
- nonce 12345 → same frame count as before this change.
- own node missing + fallback given → exactly one extra nodeInfo with the own number; own node present → no duplicate.

**Verify**: `swift test --filter VirtualNode` → all pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 with the four new tests
- [ ] `grep -n "69420\|69421" MeshHessen/Services/VirtualNodeService.swift` shows the constants
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- Frames in the cache cannot be decoded back in tests (no unframing helper in `MeshtasticStreamFrameCodec`) — report rather than writing a second codec.
- The nonce is not what is passed as `wantConfigID` at the call site.

## Maintenance notes

- Reviewer: connect the Meshtastic Android app to the Virtual Node, disconnect and reconnect — it must not loop.
- If upstream changes the special nonces, they are defined as constants in one place.
