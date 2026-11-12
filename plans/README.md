# Implementation Plans — Windows → macOS feature parity

Generated on 2026-11-12 by a feature-gap audit of the Windows client against this repo.

- **Mac baseline**: `main` @ `d470b3a` (`swift build` OK, `swift test` → 261 tests in 38 suites pass).
- **Windows reference**: `/Volumes/Dock/code/Private/mesh/mh_windowsclient`, branch `firmware_update` @ `095ea5b` (= upcoming v1.7.3). The Mac's last parity pass (release 1.1.0, 2026-07-20) targeted Windows ≈ 1.5.14, so the audit covered Windows changelog sections **1.5.14 → 1.7.3**.
- Each plan is self-contained and written for an executor with no other context. Executors: read the plan fully, run its drift check, honour its STOP conditions, never push, and update your row here when done.
- Note: `AGENTS.md` says "there are currently no test targets" — that is outdated; tests exist under `Tests/MeshHessenTests/` and run with `swift test`.

## Execution order & status

| Plan | Title | Prio | Effort | Risk | Depends on | Status |
|------|-------|------|--------|------|------------|--------|
| [001](001-channel-owner-clone-and-byte-limits.md) | Channel/owner writes never drop device fields; UTF-8 byte limits | P1 | M | MED | — | DONE (reviewed) — merged into `main` from `fix/001-channel-owner-clone` |
| [002](002-protobuf-v2.8.2-and-firmware-capabilities.md) | Protobufs v2.8.2 + firmware capability gate | P1 | S–M | MED | — | DONE (reviewed) — merged into `main` from `chore/002-protobuf-2.8.2` |
| [003](003-pki-aes-ccm-decryption.md) | PKI decryption uses AES-256-CCM | P1 | M | MED | — | DONE (reviewed) — merged into `main` from `fix/003-pki-aes-ccm` |
| [004](004-node-position-retention.md) | Node positions survive NodeInfo broadcasts and restarts | P1 | M | LOW–MED | — | DONE (reviewed) — merged into `main` from `fix/004-node-position-retention` |
| [005](005-telemetry-data-correctness.md) | Direct-RF-only signal series, requests ≠ results, chart scales | P1 | M | LOW | — | DONE (reviewed) — merged into `main` from `fix/005-telemetry-data-correctness` |
| [006](006-messaging-quick-fixes.md) | Eight messaging fixes (BEL, Enter, scroll, names, …) | P1 | M | LOW | — | DONE (reviewed) — merged into `main` from `fix/006-messaging-quick-fixes` |
| [007](007-virtual-node-two-stage-config.md) | Virtual Node two-stage config nonces | P2 | S | LOW | — | DONE (reviewed) — merged into `main` from `fix/007-virtual-node-two-stage` |
| [008](008-link-watchdog-and-handshake-metadata.md) | Link watchdog, heartbeat on BLE, metadata, ClientNotification | P1 | M | MED | — | DONE (reviewed) — merged into `main` from `fix/008-link-watchdog-metadata` |
| [009](009-map-and-admin-polish.md) | Offline map source, NodeDB reset, admin hints, quick config | P2 | M | LOW–MED | — | DONE (reviewed) — merged into `main` from `fix/009-map-and-admin-polish` |
| [010](010-firmware-2.8-small-features.md) | FW 2.8: signed ACKs, signature policy, heard flag, AEAD badge, presets | P2 | M | LOW | 002 | TODO |
| [011](011-module-forms-and-mesh-beacon.md) | Six native module forms + Mesh Beacon | P2 | M–L | LOW–MED | 002, 001 | TODO |
| [012](012-node-status.md) | Node status (port 36): show, remember, set | P2 | M | LOW | 001 | TODO |
| [013](013-telemetry-new-sensors-and-sievert.md) | Lightning + soil/water telemetry, µSv/h option | P3 | M | LOW–MED | 002 | TODO |
| [014](014-device-display-mirror.md) | Device display mirroring | P3 | M–L | LOW | 002, 008 | TODO |
| [015](015-channel-decryption-and-hf-only-traceroute.md) | Client-side channel decryption (PSK + AEAD), RF-only traceroute | P2 | L | MED | 003, 001, (002) | TODO |
| [016](016-late-pki-decryption-and-unknown-senders.md) | Late PKI decryption, auto NodeInfo for unknown senders | P2 | L | MED | 003 | TODO |
| [017](017-funk-echo-core.md) | Funk-Echo core: detection, journal, stats, indicator | P2 | L | LOW | 005 | TODO |
| [018](018-funk-echo-radar-and-airtime.md) | Funk-Echo radar, drill-down, route on map, airtime | P3 | M | LOW | 017 | TODO |
| [019](019-dashboard-warn-alarm-zones.md) | Dashboard warn/alarm zones | P2 | M | LOW–MED | 005 | TODO |
| [020](020-messages-sidebar-and-notifications.md) | Messages sidebar, inline DMs, message notifications | P2 | L | MED | 006 | TODO |
| [021](021-message-text-formatting.md) | Message text formatting + format toolbar | P3 | M | LOW | 006 | TODO |
| [022](022-rf-links-polling-and-rates.md) | RF neighbour links, telemetry polling, LocalStats rates | P3 | L | LOW–MED | 005 | TODO |
| [023](023-config-backup-restore.md) | Config backup / restore as JSON | P2 | M | MED | (001, 008) | TODO |
| [024](024-firmware-foundation.md) | Firmware: catalog, download, file inspection, admin commands | P2 | L | LOW | 008, 002 | TODO |
| [025](025-firmware-wizard-wifi-ota-uf2.md) | Firmware wizard + ESP32 Wi-Fi OTA + UF2 | P2 | L | **HIGH** | 024, 008, (023) | TODO |
| [026](026-firmware-bluetooth-ota-and-nrf-dfu.md) | Firmware: ESP32 BLE OTA + nRF52 DFU | P3 | L | **HIGH** | 025 | TODO |
| [027](027-environment-map-overlay.md) | Environment data on the map (boxes + heatmap) | P3 | L | MED | (013) | TODO |
| [028](028-terrain-link-profile-3d.md) | Terrain service, link elevation profile, 3D terrain | P3 | L | LOW–MED | (022) | TODO |
| [029](029-triangulation.md) | Position triangulation (easter egg) | P3 | L | LOW | 004, 022, (028) | TODO |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (one-line reason) | REJECTED (one-line rationale). Dependencies in parentheses are soft.

## Execution log

2026-11-12 — plans 001, 002, 003, 006, 007 executed by Opus 5.5 executors in isolated worktrees and reviewed (done criteria re-run, diffs and tests read). The five branches were then merged into `main` (merge commits `b6bdf50` … `874ba8f`) without conflicts; the combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 301 tests in 44 suites. Nothing was verified on hardware or in the running app.

Learnings that affect later plans:
- **002**: upstream protos carry `option swift_prefix = "";`, which strips the `Meshtastic_` prefix and collides with app types. The option is deleted from every copied proto (documented in `MeshHessen/Proto/README.md`). New oneof cases (`meshBeacon`, `soilWaterMetrics`, display frames) currently have neutral branches — plans 011, 013, 014 must replace them. `VirtualNodeService` does not cache MeshBeacon module-config frames for replay yet (plan 011 should add key 17). New files under `MeshHessen/Proto/` must be added to `membershipExceptions` in `project.pbxproj`.
- **003**: `AESCTR.crypt` (moved to `MeshHessen/Services/AESCCM.swift`) still requires a 32-byte key; plan 015 must allow 16-byte keys. The plan's split of the RFC vector into ciphertext/tag was wrong (correct: 23-byte ciphertext + 8-byte tag); the combined hex was right.
- **001**: a second channel entry point exists (admin config loader records into the snapshot directly); the raw cache is also rebuilt from completed local snapshots. Duplicate detection now requires name **and** PSK to match.
- **006**: a fourth alert-bell sender (`MeshtasticProtocolService.sendSOSAlert`, used by App Intents) was missed by the plan and fixed in a revision. Shift+Enter appends the newline at the end of the text, not at the cursor.
- **007**: the own-node fallback is implemented and tested but not wired: `VirtualNodeService` (an actor) cannot reach `AppState`; follow-up = a setter on the actor fed from `AppCoordinator`.
- Running several executors at once makes the first `swift build` in each fresh worktree slow or flaky (parallel clones of swift-protobuf's submodules); retrying works.

2026-11-12 (second wave) — plans 004, 005, 008, 009 executed the same way and reviewed. Merged into `main` one at a time (`89c4bc0`, `c6c14e4`, `313e761`, `4203e31`); the only conflict (008 vs 004 in `MeshtasticProtocolService.swift`: new stored properties and `disconnect()`) was resolved by keeping both sides. The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 346 tests in 48 suites. Nothing was verified on hardware or in the running app.

Learnings that affect later plans:
- **004**: new SQLite tables added to `telemetryTableNames` must also update the hard-coded table count and the "every table populated" clear test in `TelemetryDashboardParityTests.swift` (plan 022 will hit this). Clearing telemetry also deletes `node_positions` (read by 022/029). Only exact 0/0 counts as "no position". `viaMqtt` is now taken only from NodeDB snapshots in `AppState.upsertNode`; live packets set it directly.
- **005**: `TelemetryDatabaseService.signalSamples(snr:rssi:hopCount:viaMqtt:)` is the reusable direct-RF filter; `packet_count` is written as a side effect of `insertSamples(variant: "packet")`, so it is still called with empty signal values. `MeshtasticProtocolService.isIncomingRequest` (top of `handleTraceroutePacket`/`handleTelemetry`) is the hook plan 017 replaces with its classifier; it needs `myNodeId != 0`. Charts now auto-scale unless the user sets a range (`explicitDisplayRange`); the gauge still uses `effectiveDisplayRange` (plan 019).
- **008**: hooks for 014/024/025 are `protocol_.deviceMetadata`, `myNodeInfo.pioEnv/hardwareModelRaw/hasWifi/hasBluetooth` and `protocol_.onClientNotification` (not yet wired in `AppCoordinator`). Caches are cleared on `initialize()` and `disconnect()`. `myNodeInfo` can now exist with empty names. Heartbeat runs on all transports every 300 s and a stale link triggers an automatic reconnect — **plans 025/026 must suppress `onLinkStale` or stop the heartbeat while flashing.** Virtual Node frames do not feed the watchdog.
- **009**: `meshHessenPSK`/`meshHessenChannelName` are now `nonisolated static`. Quick configuration verifies by re-reading LoRa + channels only. Old string-catalog keys are left in place and show as stale in Xcode. Windows' double LoRa write for the `ignore_mqtt` coercion was deliberately not ported. `SettingsService(defaults:)` with a UUID-named suite works in tests.
- The first `swift build` in a fresh worktree took ~10 min (full clone of protocolbuffers/protobuf); the worktree guard rejects chained git commands, so executors should run git commands one per call.

## Suggested waves

1. **Bugs that lose data or break features today** (independent, can run in parallel in separate worktrees — but 001, 003, 004, 005, 008 all touch `MeshtasticProtocolService.swift`, so merge them one at a time): 001, 003, 004, 005, 006, 007, 008, 009.
2. **Firmware 2.8 enablement**: 002, then 010, 011, 012, 013 (014 after 008).
3. **Windows-only features, medium**: 017 → 018, 019, 020 → 021, 023, 016, 015.
4. **Large features**: 024 → 025 → 026 (firmware), 022 → 029, 027, 028.

## Executor sizing

- Plans with effort S/M and risk LOW are suitable for a small model as written.
- Plans marked L or risk MED/HIGH (015, 016, 020, 025, 026, 027, 029) should be run by a mid-tier model and reviewed by a human or a stronger model before merge; split them along their steps/parts if the executor's context is small.
- 025 and 026 flash real radios: unit tests cover the protocol logic only. **A human must test on hardware before release**; executors must never flash devices.

## Dependency notes

- 002 is the gate for every firmware-2.8 feature (010, 011, 013, 014 and the AEAD half of 015).
- 003 creates `AESCCM`, which 015 (AEAD channels) and 016 (late decryption) reuse.
- 001 creates `UTF8Limits` and the raw-channel cache used by 011, 012, 015, 023.
- 008 creates the metadata/`pio_env` cache and `onClientNotification` needed by 014, 024, 025.
- 005 introduces request detection that 017 turns into the Funk-Echo classifier.
- 004 (`node_positions`) and 022 (`rf_links`, `rf_link_obs`) are data prerequisites for 029.

## Findings considered and not planned

- **Bluetooth adapter display / multi-adapter hint** (Win 1.7.3): CoreBluetooth exposes no adapter name, address or selection — not applicable.
- **Automatic removal of stale Bluetooth pairings** (Win 1.7.3): macOS has no unpair API; plan 008 covers the feasible part (re-discover on service change, clear error with instructions).
- **Window minimise/focus fixes, right-click selection, dark-mode toolbar, MainWindow refactors**: WPF/Win32-specific.
- **DM/channel cross-rendering fixes** (Win 1.7.0/1.7.1): the Mac separates DMs and channel messages at receive time — not affected.
- **Encoding canary test**: Windows build-tooling safeguard; no equivalent problem on the Mac.
- **Deferred small items** (real gaps, deliberately left out to keep plans focused — good candidates for a follow-up "polish" plan): friendly role names and 🔌 for battery 101 % in Node Info; per-hop MQTT badge honesty in traceroute beyond the SNR-0 rule (plan 005); dashboard extras (time-axis zoom, PNG export, full-screen, duplicate widget, Excel-style CSV, JSON import UI, persisted refresh interval, day/night shading, adaptive moving average, greying stale stat values); pinning selected nodes on top in the widget editor's node list; native forms for the StatusMessage and TrafficManagement modules; pre-filling fixed-position fields from the NodeDB when the option is switched on; full-name tooltip on the node name column; persisting the signed-ACK flag.

## Not audited

- Windows versions before 1.5.14 (assumed covered by the Mac 1.1.0 parity release) and the Windows `ROADMAP.md` ideas that Windows itself has not implemented.
- Runtime behaviour: findings come from reading both code bases; nothing was exercised against a radio. The Mac defects in plans 001, 003, 004 and 005 were confirmed by reading the cited code, not by reproduction.
- Mac features that Windows lacks, and general code quality of either client.
