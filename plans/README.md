# Implementation Plans — Windows → macOS feature parity

Generated on 2026-11-12 by a feature-gap audit of the Windows client against this repo.

- **Mac baseline**: `main` @ `d470b3a` (`swift build` OK, `swift test` → 261 tests in 38 suites pass).
- **Windows reference**: `/Volumes/Dock/code/Private/mesh/mh_windowsclient`, branch `firmware_update` @ `095ea5b` (= upcoming v1.7.3). The Mac's last parity pass (release 1.1.0, 2026-07-20) targeted Windows ≈ 1.5.14, so the audit covered Windows changelog sections **1.5.14 → 1.7.3**.
- Each plan is self-contained and written for an executor with no other context. Executors: read the plan fully, run its drift check, honour its STOP conditions, never push, and update your row here when done.
- Note: `AGENTS.md` says "there are currently no test targets" — that is outdated; tests exist under `Tests/MeshHessenTests/` and run with `swift test`.

## Execution order & status

| Plan | Title | Prio | Effort | Risk | Depends on | Status |
|------|-------|------|--------|------|------------|--------|
| [001](001-channel-owner-clone-and-byte-limits.md) | Channel/owner writes never drop device fields; UTF-8 byte limits | P1 | M | MED | — | TODO |
| [002](002-protobuf-v2.8.2-and-firmware-capabilities.md) | Protobufs v2.8.2 + firmware capability gate | P1 | S–M | MED | — | TODO |
| [003](003-pki-aes-ccm-decryption.md) | PKI decryption uses AES-256-CCM | P1 | M | MED | — | TODO |
| [004](004-node-position-retention.md) | Node positions survive NodeInfo broadcasts and restarts | P1 | M | LOW–MED | — | TODO |
| [005](005-telemetry-data-correctness.md) | Direct-RF-only signal series, requests ≠ results, chart scales | P1 | M | LOW | — | TODO |
| [006](006-messaging-quick-fixes.md) | Eight messaging fixes (BEL, Enter, scroll, names, …) | P1 | M | LOW | — | TODO |
| [007](007-virtual-node-two-stage-config.md) | Virtual Node two-stage config nonces | P2 | S | LOW | — | TODO |
| [008](008-link-watchdog-and-handshake-metadata.md) | Link watchdog, heartbeat on BLE, metadata, ClientNotification | P1 | M | MED | — | TODO |
| [009](009-map-and-admin-polish.md) | Offline map source, NodeDB reset, admin hints, quick config | P2 | M | LOW–MED | — | TODO |
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
