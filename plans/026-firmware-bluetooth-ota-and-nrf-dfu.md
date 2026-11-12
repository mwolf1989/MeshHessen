# Plan 026: The firmware assistant can update ESP32 over Bluetooth and nRF52 over Bluetooth DFU

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `ls MeshHessen/Services/Firmware/FirmwareUpdateSession.swift MeshHessen/Views/FirmwareUpdateWizardView.swift MeshHessen/Services/Firmware/DfuPackage.swift` — all must exist (plans 024 and 025). If not: STOP.

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: HIGH (flashes real devices over a lossy link; CoreBluetooth differs from the Windows BLE stack)
- **Depends on**: plans/025-firmware-wizard-wifi-ota-uf2.md (hard)
- **Category**: direction (feature parity with Windows 1.7.3 — firmware update assistant, part 3 of 3)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Most portable nodes are only reachable over Bluetooth. Windows 1.7.3 updates ESP32 devices through the Unified OTA loader over BLE and nRF52 devices through the Adafruit bootloader's Nordic DFU (legacy and secure variants, auto-detected, with resume and stale-session recovery). This plan adds both to the Mac wizard.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift, sandboxed, `device.bluetooth` entitlement present. Existing BLE code: `MeshHessen/Services/BluetoothConnectionService.swift` (its own `CBCentralManager`, Meshtastic service UUIDs ~31–34, continuation-based bridging of delegate callbacks — follow that style: `withCheckedThrowingContinuation`).
- Reference (READ-ONLY, **authoritative** — port byte-for-byte): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`), `MeshhessenClient/Services/Firmware/`: `BleGattLink.cs`, `BleOtaTransport.cs`, `Esp32OtaUpdater.cs`, `Dfu/DfuProtocol.cs`, `Dfu/LegacyDfuTransport.cs`, `Dfu/SecureDfuTransport.cs`, `Dfu/NordicDfuUpdater.cs`, `Dfu/IDfuTransport.cs`.
- **macOS differences you must design around**: CoreBluetooth exposes no MAC addresses (Windows matches the loader by "mesh MAC or MAC+1"); a peripheral in loader/bootloader mode appears as a *different* `CBPeripheral` → discover it by scanning for the loader's **service UUID** and/or advertised name prefix. There is no unpair API and no connection-parameter API. Write-without-response pacing uses `peripheral.canSendWriteWithoutResponse` / `peripheralIsReady(toSendWriteWithoutResponse:)`; chunk size from `maximumWriteValueLength(for: .withoutResponse)`.
- Do **not** add the NordicDFU library or any other dependency without the maintainer's approval (see STOP conditions).

## Facts to port (the C# files are the truth)

**ESP32 BLE OTA** (`BleOtaTransport.cs`, `Esp32OtaUpdater.cs`): `sendOtaRequest(mode: .otaBle, sha256:)`; wait for the `ClientNotification` confirmation (must contain "BLE"); release the link; wait 5 s for the reboot; up to 5 connect attempts. Loader GATT: service `4FAFC201-1FB5-459E-8FCC-C5C9C331914B`, write characteristic `62EC0272-3EC5-11EB-B378-0242AC130005`, notify characteristic `62EC0272-3EC5-11EB-B378-0242AC130003`. Scan (2 × 10 s) for the OTA service UUID. After subscribing wait 0.5 s. Send the `OTA <size> <sha256hex>\n` start line as with-response writes split to the write length; wait up to 60 s through `ERASING` to `OK`. Stream chunks of `min(512, maxWriteLength)` bytes: each chunk is **one** write-without-response followed by **exactly one** notification — `ACK`, or `OK` for the last chunk (10 s timeout each). An `OK` before the last chunk is an error. A chunk must never be fragmented into several writes or the ACK accounting desynchronises. Final `OK` within 10 s; `ERR Hash Mismatch` = verification failure.

**nRF52 DFU orchestration** (`NordicDfuUpdater.cs`): release link, wait 1.5 s → buttonless trigger: try Secure (service `FE59`, characteristic `8EC90003-F315-4F60-9FB8-838830DAEA50`, enable indications, write `0x01`), else Legacy (service `00001530-1212-EFDE-1523-785FEABCD123`, control point `00001531-…`, enable notifications, write `[0x01, 0x04]`); a write that never completes counts as success (the device reboots). Wait 3 s, scan 3 × 8 s for a peripheral advertising `FE59` or `00001530-…` (bootloader name typically differs from the app name). Detect the protocol from advertised services, else by GATT enumeration; default Legacy. Up to 4 connect attempts; Legacy gets up to 3 whole-session attempts; Secure resumes internally. A stale Legacy session (START answered with INVALID_STATE) → connect, send RESET/ABORT, wait 4 s, retry (max 2). Total pre-start budget 5 minutes (the bootloader boots the old app after ~6 minutes idle). "Already in bootloader" recovery mode skips the trigger.

**Legacy DFU** (`LegacyDfuTransport.cs`): control point `…1531`, packet `…1532`, version `…1534` (must be ≥ 5). START `[0x01, 0x04]` then packet = 12 bytes `[softdevice size u32][bootloader size u32][app size u32]` LE; wait up to 90 s. INIT `[0x02, 0x00]`, init packet in 20-byte pieces, `[0x02, 0x01]` (init packets > 256 bytes belong to Secure packages → reject). Packet receipt notification `[0x08, n lo, n hi]` (n = 10; 5 after a mid-stream drop), then RECEIVE `[0x03]`. Stream packets of `clamp(maxWriteLength, 20, 244)` rounded down to a multiple of 4; verify every receipt (`0x11` + received-bytes u32) against the bytes sent. Then VALIDATE `[0x04]` (60 s), ACTIVATE `[0x05]` (no response expected). ABORT `[0x06]`.

**Secure DFU** (`SecureDfuTransport.cs`): control point `8EC90001-…`, packet `8EC90002-…`. SET_PRN 0; init packet as COMMAND object (type 1); SET_PRN 10; firmware as DATA objects (type 2). Per object: SELECT → if the reported offset/CRC matches what we would have sent, resume → CREATE(size ≤ max object size, default 4096) → 400 ms pause before the first chunk → packets → CALCULATE_CHECKSUM (CRC-32 IEEE over all bytes so far) → on mismatch resend with PRN 1 → EXECUTE (retry once on INVALID_OBJECT for the last object). 3 retries per object. ABORT `0x0C`. Opcode numbers and response parsing: `DfuProtocol.cs`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Dfu` / `--filter BleOta` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: new `MeshHessen/Services/Firmware/BleGattLink.swift`, `BleOtaTransport.swift`, `Esp32BleOtaUpdater.swift`, `Dfu/DfuProtocol.swift`, `Dfu/LegacyDfuTransport.swift`, `Dfu/SecureDfuTransport.swift`, `Dfu/NordicDfuUpdater.swift`; `MeshHessen/Services/Firmware/FirmwareUpdateSession.swift` and `MeshHessen/Views/FirmwareUpdateWizardView.swift` (enable the two methods); `MeshHessen/Localizable.xcstrings`; tests.

**Out of scope**: `BluetoothConnectionService` (do not reuse its central while it owns a connection — the firmware link creates its own `CBCentralManager` after the mesh link was released); bootloader upgrades; SoftDevice/bootloader DFU packages.

## Git workflow

Branch `feat/026-firmware-bluetooth`. Commit per step. Do not push.

## Steps

### Step 1: Transport abstraction + protocol logic (pure, testable)
Define `protocol DfuGattLink` (write with/without response to a characteristic, async stream of notifications, `maxWriteLength`, disconnect) and write `LegacyDfuTransport`, `SecureDfuTransport`, `BleOtaTransport` purely against it. `DfuProtocol.swift` holds opcodes, UUIDs, CRC-32 and response parsing. Unit-test each transport with a scripted fake link that plays the peer's role.

### Step 2: CoreBluetooth link
`BleGattLink` (implements `DfuGattLink`): own `CBCentralManager` on a private queue; `scan(forServices:namePrefix:timeout:)`, `connect`, `discover`, `subscribe`, write pacing as described; every delegate callback bridged with continuations; all waits have timeouts and throw typed errors (`enum FirmwareBleError: LocalizedError`).

### Step 3: Orchestrators
`Esp32BleOtaUpdater` and `NordicDfuUpdater` implementing the sequences above with progress + log callbacks, cancellation (send ABORT where the protocol has one), and the retry rules.

### Step 4: Wizard integration
Enable "Bluetooth OTA (ESP32)" — requires ESP32 family, a Bluetooth connection, firmware ≥ 2.7.17 — and "Bluetooth DFU (nRF52)" — nRF52 and Bluetooth available (also offered in recovery mode without a mesh connection) — in `FirmwareUpdateSession.availableMethods`; show the bootloader-upgrade warning for hardware with `requiresBootloaderUpgradeForOta`. After a successful Bluetooth update show the hint: "If the node no longer connects, remove it under System Settings → Bluetooth and pair again."

## Test plan

With the scripted fake link:
- Legacy: happy path byte sequence (START + sizes, INIT, PRN, RECEIVE, packets multiple of 4, receipts, VALIDATE, ACTIVATE); receipt offset mismatch → error; START → INVALID_STATE → stale-session signal; init packet > 256 bytes rejected.
- Secure: object creation sizes for a 10 000-byte image with max object 4096 → 4096/4096/1808; resume when SELECT reports a matching offset+CRC; checksum mismatch → resend; EXECUTE retry on INVALID_OBJECT for the last object only.
- BLE OTA: one notification per chunk enforced; early `OK` → error; `ERR Hash Mismatch` → verification error; chunk size = `min(512, maxWriteLength)`.
- CRC-32 known value: `crc32("123456789") == 0xCBF43926`.

**Verify**: `swift test` → all pass; app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 with the new suites; xcodebuild Debug build succeeds
- [ ] No new package dependency (`git diff d470b3a -- Package.swift Package.resolved` shows none)
- [ ] The transports contain no CoreBluetooth imports (only `BleGattLink.swift` does)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- You conclude that a hand-port of Nordic DFU is not achievable within the plan (e.g. the fake-link tests cannot be made to pass after two attempts per transport): STOP and report, recommending the alternative "use Nordic's `IOSDFULibrary` Swift package (supports macOS)". Adding that dependency is the maintainer's decision.
- CoreBluetooth cannot discover the loader/bootloader peripheral by service UUID in a manual check the reviewer performs — nothing for you to do; just make the scan criteria configurable (service UUIDs + name prefix).
- Any wish to verify by flashing a device: you must not flash hardware.

## Maintenance notes

- **Unverified on hardware.** Required human test matrix before release: ESP32-S3 BLE OTA (success, wrong hash, link drop mid-transfer); nRF52 legacy DFU (older Adafruit bootloader) and secure DFU; resume after a drop; device already in bootloader; cancel mid-transfer.
- The most fragile rule is "one write-without-response per chunk, one notification per chunk" for ESP32 BLE OTA; any change to chunking must keep it.
