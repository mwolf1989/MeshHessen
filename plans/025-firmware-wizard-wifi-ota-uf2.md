# Plan 025: A guided firmware update assistant works for ESP32 over Wi-Fi and for nRF52/RP2040 via UF2 drive

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `ls MeshHessen/Services/Firmware/FirmwareCatalogService.swift MeshHessen/Services/Firmware/FirmwareRetriever.swift MeshHessen/Services/Firmware/FirmwareFileInspector.swift MeshHessen/Services/Firmware/UnifiedOta.swift` — all must exist (plan 024). Then `git diff --stat d470b3a..HEAD -- MeshHessen/AppCoordinator.swift MeshHessen/Views/ToolsView.swift MeshHessen/MeshHessen.entitlements MeshHessen/Info.plist`.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: HIGH (flashes real devices; touches connection lifecycle and sandbox entitlements)
- **Depends on**: plans/024-firmware-foundation.md (hard), plans/008 (hard), plans/023 (optional pre-update backup)
- **Category**: direction (feature parity with Windows 1.7.3 — firmware update assistant, part 2 of 3)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

This is the user-facing firmware assistant: device & catalog → transfer method → firmware → checks → transfer → done, as in the Windows client and the Android app. This plan implements the wizard and the two transports that need no Bluetooth work: ESP32 Wi-Fi OTA and the UF2 drive copy. Bluetooth OTA and nRF52 DFU follow in plan 026 and plug into the same wizard.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI, **sandboxed**. Entitlements today (`MeshHessen/MeshHessen.entitlements`): app-sandbox, network.client, network.server, device.bluetooth, device.serial, device.usb, files.user-selected.read-write, files.downloads.read-write, and a temporary-exception absolute-path read-write for `/tmp/`. `MeshHessen/Info.plist` has Bluetooth and Location usage strings but **no** `NSLocalNetworkUsageDescription`.
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/FirmwareUpdateWindow.xaml.cs` (steps 1–6; method gating ~234–284; pre-flight ~465–574; run ~578–705; finish ~742–779), `MeshhessenClient/MainWindow.FirmwareUpdate.cs` (host hooks ~126–181), `MeshhessenClient/FirmwarePrefetchWindow.cs`, `MeshhessenClient/Services/Firmware/Esp32OtaUpdater.cs`, `WifiOtaTransport.cs`, `Uf2UsbFlasher.cs`; user doc `docs/en/firmware-update.md`.
- Multi-step wizard pattern on the Mac: `MeshHessen/Views/TDeckWizardView.swift`. Tools entry points: `MeshHessen/Views/ToolsView.swift` (sections as `private var … : some View`).
- TCP client pattern: `NWConnection` usage in `MeshHessen/Services/TcpConnectionService.swift`.
- `AppCoordinator` (`MeshHessen/AppCoordinator.swift`): `lastConnectionParameters` (~41), `userRequestedDisconnect` (~44), `disconnect()` (~264, clears `lastConnectionParameters`), `performConnect(type:parameters:isReconnect:)` (~800), `handleUnexpectedDisconnect()` (~906).
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys). Windows texts: `MeshhessenClient/Resources/Strings.en.xaml` / `Strings.de.xaml` (search "Firmware").

## Facts to port (the C# files are the truth)

**Method availability** (step 2): Wi-Fi OTA — connected, ESP32 family, firmware ≥ 2.7.17, and Wi-Fi enabled in the device's Network config (or the current connection is TCP). UF2 — nRF52 or RP2040. ESP32 over serial is deliberately not offered (show a hint to https://flasher.meshtastic.org). Bluetooth methods appear as "available in a later version" placeholders until plan 026.

**ESP32 Wi-Fi OTA sequence** (`Esp32OtaUpdater.cs`, `WifiOtaTransport.cs`):
1. SHA-256 of the image.
2. `sendOtaRequest(mode: .otaWifi, sha256:)`.
3. Wait up to 6 s for a `ClientNotification` whose message contains the word "OTA": accepted if it starts with "Rebooting to" and contains "WiFi"; any other OTA message is a refusal (show it); silence is accepted (older firmware sends nothing).
4. Release the mesh link (no auto-reconnect), wait 1 s.
5. Listen up to 20 s on UDP port 3232 for the loader's beacon (payload matching `^Meshtastic_[0-9A-F]{4}\s+\S{1,32}$`, broadcast about once per second) — the sender's IP is the loader. Fallback: the known TCP host of the last connection, after an 8 s wait.
6. TCP connect to `<ip>:3232` (no delay, 5 s timeout), up to 10 attempts 2 s apart.
7. Send `UnifiedOta.startCommand`; read lines: `ERASING` may repeat (60 s timeout) until `OK`; `ERR …` aborts.
8. Stream the image in 1024-byte chunks (10 ms pause between chunks), reporting progress.
9. Wait up to 10 s for the final `OK` (ignore late `ACK`); `ERR Hash Mismatch` = verification failure.

**UF2** (`Uf2UsbFlasher.cs`): if connected, `enterDfuMode()`, wait 0.8 s, release the link; wait up to 90 s (120 s in recovery mode, when not connected) for a newly mounted volume whose root contains `INFO_UF2.TXT`; parse it (`Board-ID:`, `SoftDevice:`, "UF2 Bootloader x.y.z"); copy the `.uf2` file to the volume root; an I/O error after the last byte counts as success (the device reboots mid-close); success = the volume unmounts within 60 s.

**Pre-flight (step 4)**: catalog online vs. cached; hardware not actively supported → warning; file inspection errors block; download + verification; battery < 30 % and not powered → warning; firmware version verdict (upgrade / same / downgrade warning); release has a build for this target; optional "back up configuration first" (plan 023).

**Finish (step 6)**: reconnect with the previous connection parameters and poll up to 120 s for the new firmware version.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter FirmwareWizard` / `--filter WifiOta` / `--filter Uf2` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: new `MeshHessen/Services/Firmware/Esp32WifiOtaUpdater.swift`, `WifiOtaTransport.swift`, `OtaBeaconListener.swift`, `Uf2VolumeFlasher.swift`, `FirmwareUpdateSession.swift` (wizard state machine, `@Observable @MainActor`); new `MeshHessen/Views/FirmwareUpdateWizardView.swift`, `FirmwarePrefetchSheet.swift`; `MeshHessen/AppCoordinator.swift` (three small host hooks); `MeshHessen/Views/ToolsView.swift` (section); `MeshHessen/Info.plist` (`NSLocalNetworkUsageDescription`); `MeshHessen/Localizable.xcstrings`; tests.

**Out of scope**: Bluetooth OTA / DFU (plan 026); changing entitlements (see STOP conditions — the UF2 copy must work through a user-granted folder); serial flashing.

## Git workflow

Branch `feat/025-firmware-wizard`. Commit per step. Do not push.

## Steps

### Step 1: Host hooks in `AppCoordinator`
- `func disconnectForFirmwareUpdate() async -> ConnectionParameters?` — like `disconnect()` but **keeps** and returns the last connection parameters and connection type, and suppresses auto-reconnect.
- `var firmwareUpdateInProgress: Bool` — while true, `handleUnexpectedDisconnect()` must not reconnect.
- `func reconnectAfterFirmwareUpdate(type:parameters:) async` — clears the flag and calls the existing connect path.
Read `disconnect()`, `handleUnexpectedDisconnect()` and `performConnect` completely before editing; reuse them.

### Step 2: Transports (pure where possible)
- `OtaBeaconListener`: BSD datagram socket bound to `0.0.0.0:3232` with `SO_REUSEADDR` + `SO_REUSEPORT`, non-blocking read loop on a background queue, returns the first sender IPv4 whose payload matches the regex; pure `static func isBeacon(_ payload: Data) -> Bool`.
- `WifiOtaTransport`: `NWConnection`-based line reader/writer implementing steps 6–9 against an abstract `protocol OtaByteStream { func send(_:) async throws; func readLine(timeout:) async throws -> String }` so the sequence logic (`Esp32WifiOtaUpdater.run(stream:image:progress:)`) is testable with a scripted fake stream.
- `Uf2VolumeFlasher`: observes `NSWorkspace.shared.notificationCenter` `didMountNotification` / `didUnmountNotification`; pure `static func parseInfoUf2(_ text: String) -> Uf2BootloaderInfo`; the copy uses a security-scoped URL obtained from an `NSOpenPanel`/`.fileImporter` folder pick of the mounted volume (prompt: "Select the boot drive of the device to allow copying the firmware"), pre-pointed at the detected volume.
- Add `NSLocalNetworkUsageDescription` to `Info.plist`: "MeshHessen uses the local network to find and update Meshtastic devices over Wi-Fi."

### Step 3: Session state machine
`FirmwareUpdateSession`: inputs = connected device facts (firmware version, `pioEnv`, hardware model number, battery level, network config Wi-Fi flag, connection type/params — from `appState.myNodeInfo`, plan 008's metadata cache and the config snapshot), catalog, chosen method, chosen release or local file. Exposes `availableMethods` (pure static function with the gating rules), `preflightItems` (pure static function producing ok/warning/error rows), `canStart`, `run()` (drives backup → method-specific updater → finish), `log` lines and `progress`. All decisions as pure static functions with tests.

### Step 4: Wizard UI
`FirmwareUpdateWizardView` (sheet from a new `firmwareSection` in `ToolsView`, pattern: `TDeckWizardView`): six steps as described; step 3 lists Stable / Alpha releases with release notes, version verdict, "available offline" marker for cached artifacts, and "Local file…" (`.fileImporter` for `.bin`, `.zip`, `.uf2`); step 5 shows progress + log and cannot be dismissed while transferring; step 6 offers "Reconnect" and shows the new firmware version. `FirmwarePrefetchSheet`: choose a release and device types from the catalog and download their artifacts into the cache (ESP32 → OTA `.bin`; nRF52 → `-ota.zip` + `.uf2`; RP2040 → `.uf2`).

### Step 5: Tests
- `WifiOtaSequenceTests`: scripted fake stream — happy path (ERASING×2, OK, …, OK) completes and sends exactly `ceil(size/1024)` chunks after the start line; `ERR Hash Rejected` after start → throws with that message; missing final OK → timeout error; late `ACK` before final `OK` tolerated.
- `OtaBeaconTests`: `"Meshtastic_AB12 somehost"` → true; lowercase hex / missing suffix → false.
- `Uf2InfoTests`: parse a sample `INFO_UF2.TXT` (write a 3-line fixture inline).
- `FirmwareWizardLogicTests`: method gating table (ESP32 + fw 2.7.16 → no Wi-Fi OTA; ESP32 + 2.7.17 + Wi-Fi configured → Wi-Fi OTA; nRF52 → UF2; RP2040 → UF2 only); pre-flight rows (battery 20 % unpowered → warning; inspector error → blocks; downgrade → warning).

**Verify**: `swift test` → all pass; app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 with the new suites; xcodebuild Debug build succeeds
- [ ] A firmware file is never transmitted unless `FirmwareFileInspector` reported no errors (enforced in `FirmwareUpdateSession.canStart`, covered by a test)
- [ ] `MeshHessen/MeshHessen.entitlements` is unchanged
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The UF2 copy cannot be done with a user-selected security-scoped folder (sandbox denies writing to the picked volume) — report; do **not** add a `/Volumes/` temporary-exception entitlement on your own.
- Receiving the UDP broadcast fails in the sandbox even with the usage description (then implement only the "known TCP host" fallback and report).
- `disconnectForFirmwareUpdate` cannot be implemented without restructuring the reconnect logic beyond ~60 changed lines.
- Any wish to "test" by flashing a device: you must not flash hardware. Hardware verification is the reviewer's job.

## Maintenance notes

- **Nothing in this plan was or can be verified on hardware by the planner or executor.** Before release a human must run: ESP32 Wi-Fi OTA on a firmware ≥ 2.7.17 device (success + wrong-hash refusal), UF2 on an nRF52 (RAK4631/T-Echo) and an RP2040 board, recovery mode with a device already in the bootloader, and an interrupted transfer.
- A failed OTA leaves ESP32 devices on the old firmware (the loader verifies the hash before switching); UF2 bootloaders are similarly safe. Say this in the UI text the way Windows does; do not promise more.
