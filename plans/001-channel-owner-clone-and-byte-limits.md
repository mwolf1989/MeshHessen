# Plan 001: Channel and owner writes never drop device fields; names are limited by UTF-8 bytes

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Models/ChannelInfo.swift MeshHessen/Views/DeviceConfigView.swift MeshHessen/Views/AddChannelSheet.swift MeshHessen/Views/NodeInfoSheet.swift`
> If these changed, compare the "Current state" excerpts with the live code first; a mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches device writes)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

`AdminMessage.set_channel` and `set_owner` replace the **whole** object on the device. Three Mac code paths rebuild that object from a lossy UI model, so deleting one channel or renaming the node silently wipes other settings: per-channel position precision (location sharing stops), channel id, mute flag, and — worst — an unnamed primary channel gets the literal name "Default", which changes its channel hash and cuts the node off from the default mesh. Windows fixed the same class of bug in 1.7.1 (issue #69). In addition the firmware rejects names that are too long in **bytes**; the Mac counts characters, so "Hütte Süd Ost" style names can make the device discard the write.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — native macOS 14+ Meshtastic client, Swift 5.9 / SwiftUI. App code in `MeshHessen/`, tests in `Tests/MeshHessenTests/`.
- Reference implementation (READ-ONLY, never edit): Windows client at `/Volumes/Dock/code/Private/mesh/mh_windowsclient`, branch `firmware_update` (commit `095ea5b`). Relevant: `MeshhessenClient/Services/ChannelEdit.cs`, `MeshhessenClient/Services/Utf8Text.cs`, `MeshhessenClient.Tests/ChannelEditTests.cs`.
- Conventions: 4-space indent; `AppLogger.shared.log(...)` for errors; `guard` early exits; never edit `MeshHessen/Generated/`.
- UI strings: English in code; add the German translation of every new string to `MeshHessen/Localizable.xcstrings`.
- New `.swift` files are picked up automatically (Xcode synchronized folders + SPM); do not edit `project.pbxproj`.
- Tests use Swift Testing (`import Testing`, `@testable import MeshHessen`, `@Suite`, `@Test`, `#expect`). Pattern: `Tests/MeshHessenTests/ChannelAdministrationTests.swift`.

## Current state

`MeshHessen/Services/MeshtasticProtocolService.swift` (line numbers at `d470b3a`, locate by symbol):

- `extractChannelName` (~1277) substitutes display names:
  ```swift
  if !s.name.isEmpty { return s.name }
  if channel.role == .primary { return "Default" }
  return "Channel \(channel.index)"
  ```
- `deleteChannel(index:)` (~3311) and `cleanupDuplicateChannels()` (~3396) rebuild every remaining slot from `appState.channels` (`ChannelInfo`: only `name`, `psk`, `role`, `uplinkEnabled`, `downlinkEnabled`):
  ```swift
  var settings = Meshtastic_ChannelSettings()
  settings.name = channelInfo.name          // may be the substituted "Default"/"Channel N"
  settings.psk = Data(base64Encoded: channelInfo.psk) ?? Data()
  ```
- `setOwner(shortName:longName:)` (~3150) builds a fresh `Meshtastic_User()` with only `shortName`, `longName`, `id`.
- `setChannel(index:name:psk:isSecondary:uplinkEnabled:downlinkEnabled:)` (~3272) builds a fresh channel (acceptable for *new* channels) but applies no name limit.
- Raw protos are available: `tempChannels.activeChannels` is `[Meshtastic_Channel]` (see `finishChannelSnapshot`, ~1248) and `handleChannel(_:sourceNodeID:)` receives every raw channel.
- `MeshHessen/Views/DeviceConfigView.swift` (~693): `draft.owner.longName = String(draft.owner.longName.prefix(39))` / `.prefix(4)` — characters, not bytes.
- `MeshHessen/Models/MessageItem.swift` `truncatingToPayloadLimit` (~217) is the existing pattern for byte-safe truncation at Character boundaries.

Firmware limits: channel name **11 UTF-8 bytes**; short name **4 bytes**; long name **39 bytes**, and **24 bytes on firmware ≥ 2.8**.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter UTF8Limit` / `swift test --filter ChannelClone` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Models/UTF8Limits.swift` (create), `MeshHessen/Services/MeshtasticProtocolService.swift`, `MeshHessen/Views/DeviceConfigView.swift`, `MeshHessen/Views/AddChannelSheet.swift`, `MeshHessen/Views/NodeInfoSheet.swift`, `MeshHessen/Views/ChannelBrowserSheet.swift`, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/ChannelCloneTests.swift` (create), `Tests/MeshHessenTests/UTF8LimitTests.swift` (create).

**Out of scope**: `ChannelConfigurationCard` save path via `saveCompleteConfiguration` (already writes whole protos — only add the name limit there); `MeshHessen/Generated/`; the display-name substitution used for UI labels (keep it, just never write it back).

## Git workflow

Branch `fix/001-channel-owner-clone`. Conventional commits (e.g. `fix: clone device channels instead of rebuilding them`). Do not push. `MeshHessen/Localizable.xcstrings` has an unrelated uncommitted change — only add your keys, do not revert or reformat it.

## Steps

### Step 1: UTF-8 limit helper
Create `MeshHessen/Models/UTF8Limits.swift`:
```swift
enum UTF8Limits {
    static let channelNameBytes = 11
    static let shortNameBytes = 4
    static let longNameBytesLegacy = 39
    static let longNameBytesV28 = 24
    static func longNameBytes(firmwareVersion: String?) -> Int   // 24 when major.minor >= 2.8, else 39
    static func clamp(_ text: String, maxBytes: Int) -> String   // Character-boundary truncation
    static func fits(_ text: String, maxBytes: Int) -> Bool
}
```
Parse the version with the leading `^(\d+)\.(\d+)`; unknown/empty version → legacy 39. If `Models/FirmwareCapabilities.swift` already exists (plan 002), use it instead of parsing again.

**Verify**: `swift build` → exit 0.

### Step 2: Keep raw channels and the raw owner
In `MeshtasticProtocolService` add `private var rawChannels: [Int: Meshtastic_Channel] = [:]` (local node only) and `private var rawOwner: Meshtastic_User?`.
- Fill `rawChannels[Int(channel.index)]` inside `handleChannel(_:sourceNodeID:)` when `sourceNodeID == myNodeId` (remove the entry when `role == .disabled`).
- Fill `rawOwner` from the own-node `Meshtastic_User` in `handleNodeInfoPacket` / `handleNodeInfo` (where `packet.from == myNodeId` / `info.num == myNodeId`) and from a `getOwnerResponse` if the file handles one (grep `getOwnerResponse`).
- Clear both where the service resets per-connection state (grep `tempChannels` resets / `resetForDisconnect` callers).

### Step 3: Pure rebuild functions
Add `static` (internal, testable) functions:
```swift
static func reindexedChannels(_ raw: [Meshtastic_Channel], removing index: Int) -> [Meshtastic_Channel]
static func deduplicatedChannels(_ raw: [Meshtastic_Channel]) -> [Meshtastic_Channel]
static func ownerForWrite(base: Meshtastic_User?, shortName: String, longName: String, nodeId: UInt32) -> Meshtastic_User
```
Rules: copy each proto (`var c = original`), change only `index` and `role` (slot 0 → `.primary`, others → `.secondary`); never touch `settings`. Duplicate detection compares `settings.name.lowercased()` **and** `settings.psk` of the raw protos (not display names); slot 0 is always kept. `ownerForWrite` copies `base` (or a fresh `Meshtastic_User` with `id = "!%08x"` when nil) and overwrites only `shortName`/`longName`.

### Step 4: Use them
Rewrite the write loops of `deleteChannel`, `cleanupDuplicateChannels`, `setOwner` to send the cloned protos. If `rawChannels` does not contain every active slot shown in `appState.channels`, **do not write**: log `"[Protocol] <fn> aborted: raw channel snapshot incomplete"` and return. After a successful write, pass each written channel through `handleChannel` (as `setChannel` already does) instead of hand-building `ChannelInfo`.

In `setChannel(...)` clamp `name` with `UTF8Limits.clamp(name, maxBytes: UTF8Limits.channelNameBytes)`.

**Verify**: `swift build` → exit 0; `grep -n "settings.name = channelInfo.name\|settings.name = ch.name" MeshHessen/Services/MeshtasticProtocolService.swift` → no matches.

### Step 5: UI limits
- `DeviceConfigView.swift` (~693): replace the two `prefix` lines with `UTF8Limits.clamp` using `longNameBytes(firmwareVersion:)` of the **target** node's firmware (use the loaded metadata in the draft/snapshot if present, else `appState.myNodeInfo?.firmwareVersion` for local, else legacy) and `shortNameBytes`. Fix the nearby help text that says "characters" to say bytes.
- `NodeInfoSheet.swift` owner save (grep `updateOwner`): clamp both names the same way before calling the coordinator.
- `AddChannelSheet.swift` and the channel name field in `ChannelConfigurationCard` (`DeviceConfigView.swift`, grep `ChannelConfigurationCard`): on change, clamp to 11 bytes and show a caption `"\(bytes)/11 bytes"`.
- `ChannelBrowserSheet.swift`: clamp imported names before calling `setChannel`.

**Verify**: app build → `** BUILD SUCCEEDED **`.

## Test plan

- `UTF8LimitTests.swift`: `"Hütte"` is 6 bytes; `clamp("ÄÖÜÄÖÜ", 11)` → 5 characters (10 bytes); an emoji is never split; `longNameBytes("2.8.1.abc") == 24`, `("2.7.26") == 39`, `(nil) == 39`.
- `ChannelCloneTests.swift`: build 3 raw channels with `settings.id`, `settings.moduleSettings.positionPrecision = 13`, empty name on the primary; `reindexedChannels(removing: 1)` keeps precision/id/psk of the survivors, primary name stays `""`, indices are 0…1; `deduplicatedChannels` keeps slot 0 and drops a later same-name+psk duplicate only; `ownerForWrite` preserves `isLicensed` and `publicKey` of the base.

**Verify**: `swift test --filter UTF8Limit` and `swift test --filter ChannelClone` → all pass; `swift test` → all pass.

## Done criteria

- [ ] `swift build` and `swift test` exit 0; the two new suites exist and pass
- [ ] No `Meshtastic_ChannelSettings()` is constructed inside `deleteChannel` or `cleanupDuplicateChannels`
- [ ] `setOwner` no longer starts from an empty `Meshtastic_User()` when `rawOwner` is known
- [ ] xcodebuild Debug build succeeds
- [ ] Only in-scope files changed (`git status`); `plans/README.md` row updated

## STOP conditions

- `handleChannel` is not the single entry point for channels received from the local device (then the raw cache would be incomplete).
- `Meshtastic_ChannelSettings` has no `moduleSettings.positionPrecision` in `MeshHessen/Generated/channel.pb.swift` (generated code differs from what this plan assumes).
- A step's verification fails twice.

## Maintenance notes

- Any future code that writes a channel or owner must start from the raw proto. Reviewers: search the diff for `Meshtastic_ChannelSettings()` and `Meshtastic_User()` constructors.
- After plan 002 (protobuf v2.8.2) the clone automatically preserves `use_aead`; no further change needed.
- Not verified on hardware by the planner — reviewer should delete a secondary channel on a real node and confirm the primary's name stays empty and position precision is unchanged.
