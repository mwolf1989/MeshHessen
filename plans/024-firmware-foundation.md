# Plan 024: Firmware catalog, artifact download, file inspection and the OTA/DFU admin commands exist as tested services

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/UpdateChecker.swift MeshHessen/Services/MapZIPArchive.swift`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: LOW (no UI, nothing flashes yet)
- **Depends on**: plans/008-link-watchdog-and-handshake-metadata.md (hard: `pioEnv`, hardware enum, `onClientNotification`); plans/002 (`FirmwareCapabilities`)
- **Category**: direction (feature parity with Windows 1.7.3 — firmware update assistant, part 1 of 3)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows 1.7.3's headline feature is a guided firmware update. This plan builds the transport-independent, fully unit-testable half: resolving which hardware is connected, listing official releases, downloading and verifying the right artifact, inspecting a firmware file so the wrong image can never be started, and the two admin commands that put a device into update mode. Plans 025 (wizard + Wi-Fi OTA + UF2) and 026 (Bluetooth OTA + nRF52 DFU) build on it.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift, **sandboxed** app (network client entitlement present); tests in `Tests/MeshHessenTests/` (Swift Testing; `UpdateCheckerTests.swift` shows how URLSession-based code is tested here — follow its stubbing approach).
- Reference (READ-ONLY, **authoritative** — port logic and tests from here): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`), folder `MeshhessenClient/Services/Firmware/`: `FirmwareModels.cs`, `FirmwareCatalogService.cs`, `FirmwareRetriever.cs`, `FirmwareFileInspector.cs`, `Dfu/DfuPackage.cs`, `UnifiedOta.cs`; protocol side `MeshhessenClient/Services/MeshtasticProtocolService.cs` (~3854–3877); user doc `docs/en/firmware-update.md`.
- Existing Mac building blocks: `SemanticVersion` in `MeshHessen/Services/UpdateChecker.swift`; ZIP reading with raw-deflate support in `MeshHessen/Services/MapZIPArchive.swift` (`extract(from:to:)`); CryptoKit for `SHA256` / `Insecure.MD5`.
- Admin command pattern in `MeshHessen/Services/MeshtasticProtocolService.swift` (`requestDeviceMetadata`, ~1455): `await ensureSessionKey(); guard !sessionPasskey.isEmpty …; var admin = Meshtastic_AdminMessage(); admin.<field> = …; admin.sessionPasskey = sessionPasskey; await sendAdminMessage(admin)`.
- Generated protobuf support already present: `AdminMessage.otaRequest` (`Meshtastic_AdminMessage.OTAEvent` with `rebootOtaMode`, `otaHash`), `Meshtastic_OTAMode` (`.noRebootOta`, `.otaBle`, `.otaWifi`), `enterDfuModeRequest` — confirm spellings by grep in `MeshHessen/Generated/admin.pb.swift`.

## Facts to port (summary — the C# files are the truth)

**Catalog** (`FirmwareCatalogService.cs`): `GET https://api.meshtastic.org/resource/deviceHardware` and `GET https://api.meshtastic.org/github/firmware/list`, 25 s timeout. Hardware entry fields: `hwModel`, `hwModelSlug`, `platformioTarget`, `architecture`, `activelySupported`, `displayName`, `requiresDfu`, `requiresBootloaderUpgradeForOta`, `supportLevel`. Releases: `releases.stable[]` / `releases.alpha[]` with `id`, `title`, `page_url`, `zip_url`, `release_notes`. Both raw documents are cached on disk and used (with their timestamp) when offline. `ResolveHardware`: match by `hwModel` number; several matches are disambiguated by the device's `pio_env` (exact, then case-insensitive, then first); the device's `pio_env` overrides the catalog target. Architecture fallback by keyword table (`GuessArchitecture`).

**Retriever** (`FirmwareRetriever.cs`): base `https://release.meshtastic.org/<version>/firmware-<target>-<version><suffix>`. ESP32 order: `.mt.json` manifest (entry with `part_name == "app0"`, verify `md5` + `bytes`) → `-update.bin` → `.bin` → legacy release zip. nRF52 Bluetooth DFU: `-ota.zip`. UF2 (nRF52 / RP2040): `.uf2`. Download to `<name>.part`, verify, rename. Cache layout `firmware/<version>/<file>`; `findCachedArtifact` marks a release as available offline. Release target list: when `zip_url` ends in `.json` it is `{"targets":[{"board":…}]}`.

**Inspector** (`FirmwareFileInspector.cs`): file-name rules (reject names containing `littlefs-`, `bleota`, `mt-`, `.factory.`), version from file name; UF2: block magics `0x0A324655` / `0x9E5D5157`, flag `0x2000` → family id at offset 28 (nRF52840 `0xADA52840`, RP2040 `0xE48BFF56`, RP2350 `0xE48BFF59/5A/5B`, RP2 absolute `0xE48BFF57`); ESP image: first byte `0xE9`, `chip_id` UInt16 LE at offset 12 (esp32 0, s2 2, c3 5, s3 9, c2 0x0C, c6 0x0D, h2 0x10), app-descriptor magic `0xABCD5432` at offset 0x20 must be present (otherwise it is a factory/bootloader image), version string at 0x30 (32 bytes), project name at 0x50; DFU zip: `manifest.json` → `manifest.application.{bin_file, dat_file}`, refuse packages without an application image, entries capped at 8 MB. Result = list of errors (block start) and warnings.

**Unified OTA start line** (`UnifiedOta.cs`): `"OTA <size> <sha256 lowercase hex>\n"`; responses `OK […]`, `ERASING`, `ACK`, `ERR <message>`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Firmware` | all pass |
| All tests | `swift test` | all pass |

## Scope

**In scope** (all new unless noted): `MeshHessen/Services/Firmware/FirmwareModels.swift`, `FirmwareCatalogService.swift`, `FirmwareRetriever.swift`, `FirmwareFileInspector.swift`, `DfuPackage.swift`, `UnifiedOta.swift`; `MeshHessen/Services/MeshtasticProtocolService.swift` (two admin senders); `MeshHessen/Services/MapZIPArchive.swift` (only if an in-memory "read one entry" function is needed — add, do not change existing behaviour); tests `Tests/MeshHessenTests/FirmwareCatalogTests.swift`, `FirmwareRetrieverTests.swift`, `FirmwareFileInspectorTests.swift`, `UnifiedOtaTests.swift`.

**Out of scope**: any UI; any transport (TCP/UDP/BLE/volume copy); actually sending the admin commands from anywhere.

## Git workflow

Branch `feat/024-firmware-foundation`. One commit per service. Do not push.

## Steps

### Step 1: Models
Port `FirmwareModels.cs` to Swift value types (`DeviceHardware`, `FirmwareRelease`, `FirmwareArchitecture` enum: esp32 family / nrf52 / rp2040 / unknown, `FirmwareArtifactKind`: espOtaBin / nrfOtaZip / uf2, `FirmwareUpdateMethod`: wifiOta / bleOta / bleDfu / uf2).

### Step 2: Catalog service
`final class FirmwareCatalogService` with an injectable `URLSession` and cache directory (default: `Application Support/MeshHessen/firmware/`). `func load(forceRefresh:) async -> FirmwareCatalog` (never throws: falls back to cache, reports `isFromCache` + `cacheDate`, or an empty catalog with an error message). Pure static parsers `parseHardware(_ data: Data)`, `parseReleases(_ data: Data)`, `resolveHardware(hwModel:pioEnv:in:)`. User-Agent: `MeshHessen-FirmwareWizard/1.0` (no personal data).

### Step 3: Retriever
`FirmwareRetriever` with injectable `URLSession` + cache directory: `artifactURLCandidates(release:target:kind:)` (pure), `cachedArtifact(...)`, `download(...) async throws -> URL` (progress callback, `.part` + verify + rename, MD5/size check for manifest entries), `releaseTargets(for:) async -> Set<String>?`.

### Step 4: Inspector + DFU package
`FirmwareFileInspector.inspect(fileURL:expected: FirmwareArchitecture, kind:) -> FirmwareInspection { errors: [String], warnings: [String], detectedVersion: String?, detectedChip: String? }` and `DfuPackage(zipURL:) throws` exposing `applicationBinary: Data`, `initPacket: Data`. Read ZIP entries through `MapZIPArchive` (extract to a temporary directory under `FileManager.default.temporaryDirectory`, read, delete) unless you add an in-memory reader.

### Step 5: Unified OTA grammar
`enum UnifiedOta { static func startCommand(size: Int, sha256: Data) -> String; static func parse(line: String) -> Response }` with `enum Response { ok(details: String?), erasing, ack, error(String), unknown(String) }`.

### Step 6: Admin senders
In `MeshtasticProtocolService`:
```swift
func sendOtaRequest(mode: Meshtastic_OTAMode, sha256: Data) async -> Bool     // requires sha256.count == 32
func enterDfuMode() async -> Bool
```
following the admin command pattern. No callers yet.

**Verify**: `swift build` exit 0 after each step.

## Test plan

Port the corresponding C# tests where they exist (check `MeshhessenClient.Tests/` for firmware-related test files; at `095ea5b` there may be none — then write these):
- Catalog: parse a small hand-written hardware JSON and release JSON (create minimal fixtures inline in the test); `resolveHardware` disambiguation by `pioEnv`; offline fallback uses the cache file.
- Retriever: candidate URL order for ESP32 / nRF52 / UF2; manifest entry selection (`app0`) and MD5 mismatch → error; `.part` file is removed on failure.
- Inspector: synthetic byte buffers — valid ESP32-S3 app image (0xE9, chip id 9, descriptor magic) → no errors for S3, error for expected ESP32-C3; image without descriptor magic → "factory image" error; UF2 block with nRF52840 family id → ok for nRF52, error for RP2040; file names `firmware-heltec-v3-2.7.17.abc-update.bin` (ok) vs. `littlefs-…bin` (rejected).
- UnifiedOta: `startCommand(size: 1024, sha256: 32 zero bytes)` == `"OTA 1024 " + 64×"0" + "\n"`; parse each response kind.

**Verify**: `swift test --filter Firmware` and `--filter UnifiedOta` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 with the four new suites
- [ ] No network access in tests (URLSession stubbed or pure parsers only)
- [ ] `grep -n "func sendOtaRequest\|func enterDfuMode" MeshHessen/Services/MeshtasticProtocolService.swift` → 2 matches
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The live API responses (if you look at them) differ structurally from what the C# parser expects — report; do not invent a schema.
- `MapZIPArchive` cannot read a standard deflate ZIP produced by `zip` (test with a tiny fixture created via `/usr/bin/zip` in the test).
- `Meshtastic_AdminMessage` lacks `otaRequest` or `enterDfuModeRequest`.

## Maintenance notes

- Firmware files are executable code for the radio: every download must be verified (manifest MD5/size where available) and every file must pass the inspector before any later plan transmits it.
- The cache lives inside the sandbox container; a "pre-download for offline use" dialog (Windows has one) is part of plan 025.
