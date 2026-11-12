# Plan 008: Dead links are detected and re-established; device metadata and client notifications are captured

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/SerialConnectionService.swift MeshHessen/Services/BluetoothConnectionService.swift MeshHessen/AppCoordinator.swift MeshHessen/Models/MyNodeInfo.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (connection lifecycle)
- **Depends on**: none (plan 024/025 build on the metadata and notification hooks added here)
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Meshtastic firmware closes its client API 15 minutes after the last message **sent by the client** and then silently stops delivering packets while the port/socket stays open. Windows 1.7.3 added a watchdog: firmware ≥ 2.8 answers every client heartbeat with a `queueStatus`; if two heartbeats go unanswered (or, on older firmware, nothing at all arrives for 45 minutes) the link is declared dead and reconnected. The Mac sends heartbeats on serial/TCP but never over Bluetooth, never checks for answers, and its only liveness check is a serial timer that disconnects after 30 s without any byte — which can false-trigger on a quiet mesh. Also needed by later plans: the Mac drops device metadata if it arrives before the own NodeInfo, keeps neither `pio_env` nor the hardware-model enum, and ignores `ClientNotification` frames.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift; tests in `Tests/MeshHessenTests/` (Swift Testing). Baseline: `swift test` → 261 pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/LinkWatchdog.cs` (pure logic, port 1:1), `MeshhessenClient.Tests/LinkWatchdogTests.cs`, `MeshhessenClient/MainWindow.Link.cs`.
- `AppCoordinator` (`@Observable @MainActor`) owns the connection lifecycle; `MeshtasticProtocolService` is reached as `coordinator.protocol_`.

## Current state

`MeshHessen/Services/MeshtasticProtocolService.swift`:
```swift
// 10. Start TCP heartbeat to prevent idle disconnects        (~line 307)
if gotBasicInfo && connectionService?.type != .bluetooth {
    startHeartbeat()
}
...
private func startHeartbeat() {                                (~line 3479)
    stopHeartbeat()
    heartbeatTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            ...
            var toRadio = Meshtastic_ToRadio()
            toRadio.heartbeat = Meshtastic_Heartbeat()
            await self.sendRaw(toRadio)
```
`handleFromRadio` (~538) dispatches `.packet/.myInfo/.nodeInfo/.channel/.config/.moduleConfig/.configCompleteID/.metadata/.mqttClientProxyMessage`; `.queueStatus` and `.clientNotification` fall into `default: break`. `.myInfo` stores only `myNodeId = info.myNodeNum`.

```swift
private func handleDeviceMetadata(_ meta: Meshtastic_DeviceMetadata) {     (~line 1445)
    if !meta.firmwareVersion.isEmpty { appState?.myNodeInfo?.firmwareVersion = meta.firmwareVersion }
    if meta.hwModel != .unset { appState?.myNodeInfo?.hardwareModel = hardwareModelName(meta.hwModel) }
```
`appState.myNodeInfo` is nil until the own NodeInfo arrived, so the optional chain silently drops the values.

`MeshHessen/Models/MyNodeInfo.swift`: `nodeId, shortName, longName, hardwareModel (String), firmwareVersion`. It is re-created in `handleNodeInfoPacket`/`handleNodeInfo` with `firmwareVersion: existingFW`.

`MeshHessen/Services/SerialConnectionService.swift` `startWatchdog()` (~88): 10 s timer, disconnects when `Date().timeIntervalSince(lastReceiveTime) > 30`.

`MeshHessen/AppCoordinator.swift`: `userRequestedDisconnect` (~44), `handleUnexpectedDisconnect()` (~906) drives auto-reconnect.

`MeshHessen/Services/BluetoothConnectionService.swift` `didDiscoverServices` (~563): when the Meshtastic service is missing the continuation is resumed with `ConnectionError.cancelled`; `peripheral(_:didModifyServices:)` is not implemented.

Windows watchdog rules (`LinkWatchdog.cs`): heartbeat every **5 min** with `nonce = 0` (a non-zero nonce makes the firmware broadcast NodeInfo — never do that); every received FromRadio frame resets the silence clock; a `queueStatus` within 1 min after a heartbeat marks the device as "answers heartbeats" and resets the unanswered counter; each heartbeat increments the unanswered counter. Stale when (answers heartbeats AND unanswered ≥ 2 AND silence > 5 min) OR silence > 45 min. Reported once per silence period.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter LinkWatchdog` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Services/LinkWatchdog.swift` (create), the five files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/LinkWatchdogTests.swift` (create).

**Out of scope**: firmware update (plans 024–026), TCP transport internals, reconnect back-off policy.

## Git workflow

Branch `fix/008-link-watchdog`. Conventional commits per step. Do not push.

## Steps

### Step 1: Pure `LinkWatchdog`
Create `MeshHessen/Services/LinkWatchdog.swift` as a `struct` with injected time (`Date` parameters, no timers):
```swift
struct LinkWatchdog {
    static let heartbeatInterval: TimeInterval = 300
    mutating func reset(now: Date)
    mutating func onHeartbeatSent(now: Date)
    mutating func onFrameReceived(isQueueStatus: Bool, now: Date)
    mutating func checkStale(now: Date) -> Bool      // true at most once per silence period
}
```
Port the rules above from `LinkWatchdog.cs` and port its tests to `LinkWatchdogTests.swift`.

**Verify**: `swift test --filter LinkWatchdog` → pass.

### Step 2: Wire it into the protocol service
- Add `private var linkWatchdog = LinkWatchdog()` and `var onLinkStale: (() -> Void)?`.
- At the top of `handleFromRadio`: `linkWatchdog.onFrameReceived(isQueueStatus: <payloadVariant is .queueStatus>, now: Date())`.
- Start the heartbeat for **all** transports (remove the Bluetooth exclusion), interval `LinkWatchdog.heartbeatInterval`. In the loop: check `linkWatchdog.checkStale(now:)` first — if true, log `"[Protocol] Link stale — requesting reconnect"`, call `onLinkStale?()` and break; otherwise send the heartbeat (unchanged, nonce 0) and call `onHeartbeatSent`.
- Call `linkWatchdog.reset(now:)` when the heartbeat starts.

### Step 3: Reconnect on stale link
In `AppCoordinator`, where the protocol service callbacks are wired (grep `onMqttProxyMessageReceived`), set `protocol_.onLinkStale` to: tear down the active connection **without** setting `userRequestedDisconnect`, then run the same path as an unexpected transport disconnect (`handleUnexpectedDisconnect()`). Read that function first and reuse it; do not write a second reconnect loop.

### Step 4: Relax the serial watchdog
In `SerialConnectionService.startWatchdog()` remove the 30-second receive timeout (the protocol-level watchdog now covers silence). Keep the timer only if it does something else; otherwise delete `startWatchdog`, its call and `watchdogTimer`. Port-removal detection via ORSSerialPort delegate callbacks stays untouched.

### Step 5: Metadata, pio_env, hardware enum
- Extend `MyNodeInfo` with `var pioEnv: String = ""`, `var hardwareModelRaw: Int = 0`, `var hasWifi = false`, `var hasBluetooth = false` (defaults so existing initialisers keep compiling).
- In `MeshtasticProtocolService` cache `private var lastDeviceMetadata: Meshtastic_DeviceMetadata?` and `private var lastPioEnv = ""` (from `.myInfo`: `info.pioEnv`). Expose `var deviceMetadata: Meshtastic_DeviceMetadata? { lastDeviceMetadata }`.
- `handleDeviceMetadata`: store the cache; if `appState?.myNodeInfo == nil` and `myNodeId != 0`, create a `MyNodeInfo` with empty names; then apply firmware/hardware/new fields.
- Wherever `MyNodeInfo(...)` is re-created (two places, grep `MyNodeInfo(`), re-apply the cached metadata fields and `pioEnv` so they are not lost.
- Clear both caches on disconnect.

### Step 6: ClientNotification
Add `var onClientNotification: ((Meshtastic_ClientNotification) -> Void)?` and a `case .clientNotification(let note):` in `handleFromRadio` that logs `"[Protocol] ClientNotification: \(note.message)"` (non-debug) and calls the callback. No UI in this plan.

### Step 7: Bluetooth "service missing" is a real error
- Add a case `serviceNotFound` to `ConnectionError` (defined in `MeshHessen/Services/ConnectionService.swift` or `TcpConnectionService.swift` — grep `enum ConnectionError`) with `errorDescription`: "The Meshtastic Bluetooth service was not found on this device. If the node's firmware was updated, remove it under System Settings → Bluetooth (Forget This Device) and connect again." Mark it permanent in `isPermanent` so auto-reconnect does not loop.
- In `didDiscoverServices`, when the service is missing: retry `discoverServices` once; if still missing resume with `.serviceNotFound`.
- Implement `peripheral(_:didModifyServices:)` to call `peripheral.discoverServices([<Meshtastic service UUID>])` again.

**Verify**: `swift build` exit 0; xcodebuild Debug build succeeds.

## Test plan

`LinkWatchdogTests.swift` (ported from Windows): fresh watchdog not stale; device that answered a heartbeat → stale after 2 unanswered heartbeats and > 5 min silence; device that never answered → not stale at 44 min, stale at 46 min; any frame resets silence; stale is reported once until a frame arrives.

**Verify**: `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 including `LinkWatchdog` suite
- [ ] `grep -n "type != .bluetooth" MeshHessen/Services/MeshtasticProtocolService.swift` no longer gates `startHeartbeat`
- [ ] `grep -n "> 30" MeshHessen/Services/SerialConnectionService.swift` → no watchdog timeout
- [ ] xcodebuild Debug build succeeds; only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `handleUnexpectedDisconnect()` cannot be reused for a protocol-initiated teardown without changing its signature in a way that affects other callers.
- Heartbeats over BLE cause a send error path in `sendRaw` for Bluetooth (read `sendRaw` first).
- `Meshtastic_MyNodeInfo` has no `pioEnv` field in `MeshHessen/Generated/mesh.pb.swift`.

## Maintenance notes

- Not verifiable by unit tests: the reconnect itself. Reviewer should connect via TCP, block the radio's traffic (or power-cycle it with the socket held) and confirm a reconnect within ~10–12 minutes on firmware ≥ 2.8.
- With a 5-minute heartbeat, firmware ≥ 2.8 produces one `queueStatus` per 5 minutes — harmless.
