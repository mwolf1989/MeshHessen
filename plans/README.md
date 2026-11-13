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
| [010](010-firmware-2.8-small-features.md) | FW 2.8: signed ACKs, signature policy, heard flag, AEAD badge, presets | P2 | M | LOW | 002 | DONE (reviewed) — merged into `main` from `feat/010-fw28-small-features` |
| [011](011-module-forms-and-mesh-beacon.md) | Six native module forms + Mesh Beacon | P2 | M–L | LOW–MED | 002, 001 | DONE (reviewed) — merged into `main` from `feat/011-module-forms-mesh-beacon` |
| [012](012-node-status.md) | Node status (port 36): show, remember, set | P2 | M | LOW | 001 | DONE (reviewed) — merged into `main` from `feat/012-node-status` |
| [013](013-telemetry-new-sensors-and-sievert.md) | Lightning + soil/water telemetry, µSv/h option | P3 | M | LOW–MED | 002 | DONE (reviewed) — merged into `main` from `feat/013-telemetry-sensors-sievert` |
| [014](014-device-display-mirror.md) | Device display mirroring | P3 | M–L | LOW | 002, 008 | DONE (reviewed) — merged into `main` from `feat/014-device-display-mirror` |
| [015](015-channel-decryption-and-hf-only-traceroute.md) | Client-side channel decryption (PSK + AEAD), RF-only traceroute | P2 | L | MED | 003, 001, (002) | DONE (reviewed) — merged into `main` from `feat/015-channel-decryption` |
| [016](016-late-pki-decryption-and-unknown-senders.md) | Late PKI decryption, auto NodeInfo for unknown senders | P2 | L | MED | 003 | DONE (reviewed) — merged into `main` from `feat/016-late-pki-decryption` |
| [017](017-funk-echo-core.md) | Funk-Echo core: detection, journal, stats, indicator | P2 | L | LOW | 005 | DONE (reviewed) — merged into `main` from `feat/017-funk-echo-core` |
| [018](018-funk-echo-radar-and-airtime.md) | Funk-Echo radar, drill-down, route on map, airtime | P3 | M | LOW | 017 | DONE (reviewed) — merged into `main` from `feat/018-funk-echo-radar` |
| [019](019-dashboard-warn-alarm-zones.md) | Dashboard warn/alarm zones | P2 | M | LOW–MED | 005 | DONE (reviewed) — merged into `main` from `feat/019-dashboard-zones` |
| [020](020-messages-sidebar-and-notifications.md) | Messages sidebar, inline DMs, message notifications | P2 | L | MED | 006 | DONE (reviewed) — merged into `main` from `feat/020-messages-sidebar` |
| [021](021-message-text-formatting.md) | Message text formatting + format toolbar | P3 | M | LOW | 006 | DONE (reviewed) — merged into `main` from `feat/021-message-formatting` |
| [022](022-rf-links-polling-and-rates.md) | RF neighbour links, telemetry polling, LocalStats rates | P3 | L | LOW–MED | 005 | DONE (reviewed) — merged into `main` from `feat/022-rf-links-polling` |
| [023](023-config-backup-restore.md) | Config backup / restore as JSON | P2 | M | MED | (001, 008) | DONE (reviewed) — merged into `main` from `feat/023-config-backup-restore` |
| [024](024-firmware-foundation.md) | Firmware: catalog, download, file inspection, admin commands | P2 | L | LOW | 008, 002 | DONE (reviewed) — merged into `main` from `feat/024-firmware-foundation` |
| [025](025-firmware-wizard-wifi-ota-uf2.md) | Firmware wizard + ESP32 Wi-Fi OTA + UF2 | P2 | L | **HIGH** | 024, 008, (023) | DONE (reviewed, **not hardware-tested**) — merged into `main` from `feat/025-firmware-wizard` |
| [026](026-firmware-bluetooth-ota-and-nrf-dfu.md) | Firmware: ESP32 BLE OTA + nRF52 DFU | P3 | L | **HIGH** | 025 | DONE (reviewed, **not hardware-tested**) — merged into `main` from `feat/026-firmware-ble` |
| [027](027-environment-map-overlay.md) | Environment data on the map (boxes + heatmap) | P3 | L | MED | (013) | DONE (reviewed) — merged into `main` from `feat/027-environment-map-overlay` |
| [028](028-terrain-link-profile-3d.md) | Terrain service, link elevation profile, 3D terrain | P3 | L | LOW–MED | (022) | DONE (reviewed) — merged into `main` from `feat/028-terrain-link-profile` |
| [029](029-triangulation.md) | Position triangulation (easter egg) | P3 | L | LOW | 004, 022, (028) | DONE (reviewed) — merged into `main` from `feat/029-triangulation` |

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

2026-11-13 (third wave) — plans 010–014 executed the same way and reviewed. Merged into `main` one at a time (`0b76112` 011, `a4b90f0` 012, `8ed9dc2` 010, `d20f685` 013, `dbd68b8` 014). Conflicts: `NodeListView.swift` (010's heard-on-LoRa icon vs 012's status icon — both kept) and `Localizable.xcstrings` (every branch appended keys at the end; resolved by adding each branch's new keys to `main`'s file as text). The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 389 tests in 52 suites. Nothing was verified on hardware or in the running app.

Learnings that affect later plans:
- **010**: `AppState.updateDeliveryState` takes `ackProof:`; `MeshtasticProtocolService.channelInfo(from:)` is `nonisolated static` (reuse in 015, with `ChannelInfo.useAead`). `ackProof`, `heardOnCurrentLora` and `useAead` are in memory only (channels from the store come back with `useAead == false`). `.displayLabel` helpers for enums live in `MeshEnums.swift`.
- **011**: `requestCompleteConfiguration` takes `knownFirmwareVersion:` and drops firmware-2.8-only modules (TAK, Mesh Beacon) when the version is known to be older. `MeshModuleConfigCategory` has 17 cases. `typedModuleEditor` still has a `case .statusMessage, .trafficManagement:` placeholder. `broadcast_offer_region` is not editable yet. Numeric config fields take `String` titles, so their labels are not localised (pre-existing).
- **012**: node status lives in the `node_status` table, deliberately **not** in `telemetryTableNames` (clear/retention leave it alone; 023 may want to back it up). Status is backfilled only for nodes known at handshake end. `nodeStatusMaxBytes = 79`.
- **013**: telemetry table count is now 14 (022 must update it again). Alarm and display bounds are in the *displayed* unit — 019 should use `metric.displayValue` / `displaySuggestedRange`; `effectiveDisplayRange` is still in the stored unit. Small follow-up: the metric picker label in `TelemetryDashboardView.swift` still says "Radiation (µR/h)" and the widget editor's range/alarm fields show no unit. 027 can enumerate `SoilWaterTelemetrySample.metrics` plus the two lightning metrics.
- **014**: `onDisplayFrame` / `onDisplayPalette` have a single owner (the open window); switch to fan-out if a second consumer appears. `ensureSessionKey`'s polling loop spins for up to 4 s inside a cancelled task (`try? Task.sleep` returns immediately).
- The Xcode project uses folder-synchronised groups: new Swift files need no `project.pbxproj` change (only `Proto/` exceptions do). Executors should give scratchpad helper scripts unique names — concurrent agents overwrote each other's `xcstrings.py`.

2026-11-13 (fourth wave) — plans 015, 016, 017, 019, 020, 023 executed the same way and reviewed. Merged into `main` one at a time (015 `64d2749`, 019 `8cb633a`, 023 `25eb880`, 016 `e2a5540`, 017 `cd9e6f9`, 020 `682bb96`). Conflicts: `MeshtasticProtocolService.swift` `.decoded` case (015's shared `dispatchDecoded` vs 016's `noteGoodChannel` vs 017's `recordRequestEcho` — all three kept, in that order: note channel, record echo, dispatch), `SettingsService.swift` (017 Funk-Echo and 020 Messaging sections — both kept) and `Localizable.xcstrings` (text append as before). Integration fixes by the coordinator: 015's channel-key fallback also calls `recordRequestEcho`; 016's late-decrypted DMs now go through 020's `MessageNotificationService` with `entry.receivedAt` as message date (`abee3be`). The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 493 tests in 66 suites. Nothing was verified on hardware or in the running app.

Encrypted-packet order in `.encrypted` is now: own TCP echo → client-side PKI → channel key (015, hash-matched only) → `handleEncryptedPacket` (016 routing: drop foreign unicasts, broadcast placeholder, buffered DM placeholder + NodeInfo request).

Learnings that affect later plans:
- **015**: `ChannelCrypto.*` (`ChannelCryptoService.swift`), `dispatchDecoded`, `knownCryptoChannels()` and static `rfOnlyTraceroutePacket` are reusable. PKI- and channel-decrypted packets now also reach the admin, waypoint and neighbour-info handlers. `AESCTR.crypt` takes 16- and 32-byte keys. During `requestAllDeviceConfigs` the LoRa config is briefly cleared, so unnamed channels hash as "LongFast" then.
- **016**: Core Data model is at **version 5** (`cipher` on `MHMessageEntity`); the next change needs version 6 and `TestModelFactory` updates. Unnamed nodes are now "Meshtastic abcd" everywhere (`NodeInfo.placeholderName`). `dispatchLateDecrypted` keeps its own portnum switch (text goes through `applyLateDecryptedText`). Restored pending entries are re-stamped at reconnect. Retroactive renames are in memory until the next load. A buffered emoji reaction leaves the encrypted bubble in place.
- **017**: `request_echo` is **not** in `telemetryTableNames` (own retention/clear; table count stays 14). For 018: extend `RequestEchoTab` / `content` in `RequestEchoView.swift`, `RequestEchoRecord.routeNodeIds`, `RequestEchoNodeLabels`, `appState.lastRequestEcho` (live hook), private `RequestEchoRowActions`. `ChannelInfo.positionPrecision` is in memory only. `isIncomingRequest` is still the guard in traceroute/telemetry handlers.
- **019**: thresholds are gone — widgets have `warnMinimum/warnMaximum/alarmMinimum/alarmMaximum` (displayed unit); legacy `threshold` decodes to `alarmMaximum`. Zone state persists under `telemetryAlarmZones.v2`. The gauge is a custom dial. Old alarm strings are stale in the catalogue.
- **020**: `ChannelTabsView.swift` is deleted; Messages tab is `MessagesSidebarView` (`HSplitView`). Open DMs only through `coordinator.openDirectMessage(nodeId:openWindow:)`; select from elsewhere with `appState.messagesSidebarRequest` + `selectedTab = .messages`. For 021: composers are shared between sidebar and DM window; strip markup in `MessageNotificationService.handleIncoming`. The alert bell still fires for backlog messages. `MessageNotificationService` posts to `UNUserNotificationCenter` directly and skips outside an `.app` bundle.
- **023**: for 025 — `AppCoordinator.exportConfigurationBackup(progress:)` (tens of seconds; run before stopping heartbeat/watchdog), `ConfigBackupDocument`, `file.defaultFileBaseName()`, `restoreConfigurationBackup(file)` (re-reads, writes differences, expects reboot, no read-back check). Security keys restore only onto the same node id. `MeshConfigCategory(config:)` / `MeshModuleConfigCategory(moduleConfig:)` map protos to categories. Node status, fixed position, canned messages and ringtone are not backed up.
- **Xcode-only gotcha**: the app target enforces `MemberImportVisibility` — any file using `Meshtastic_*(serializedBytes:)` or other SwiftProtobuf API needs `import SwiftProtobuf`, even though `swift build` passes without it. Always run the `xcodebuild` check.

2026-11-13 (fifth wave) — plans 018, 021, 022, 024, 027 executed the same way and reviewed. Merged into `main` one at a time (021 `4ba5a7d`, 022 `10ee8ef`, 018 `6ea23cd`, 024 `b3dbd33`, 027 `83e4cd8`). Conflicts: `Localizable.xcstrings` (text append as before) and `TelemetryDatabaseService.swift` (022's RF-link section and 027's environment query were inserted at the same spots; resolved by re-applying 027's diff onto `main`'s file). Coordinator fix: Funk-Echo "Send DM" now goes through `coordinator.openDirectMessage` (018 still used the pre-020 path). The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 618 tests in 83 suites. Nothing was verified on hardware or in the running app.

Learnings that affect later plans:
- **018**: `LoRaAirtime` (port of `LoRaAirtime.cs`) and `MeshtasticProtocolService.currentModemPreset` (nil for custom LoRa parameters). `RequestEchoRowActions` / `RequestEchoNodeMenu` are shared by journal and radar. Pushing traceroutes onto the map from outside `MapView` needs a short delay after switching tabs, because `MapView` only turns the traceroute layer on in an `onChange` of `TracerouteMapSelectionStore` — a cleaner fix is for `MapView` to check the store on appear (small follow-up). Airtime and radar see only the first 500 journal rows.
- **021**: `MessageFormatting.attributed` / `plainText` / `wrap` / `insertLink`; only http/https links are clickable (bare e-mail addresses no longer are). Backslash escapes are consumed (`a\*b` → `a*b`); `_x_` is italic on the Mac but not on Windows.
- **022**: tables `rf_links(observer, neighbor, snr NULL, source 'rx'|'neighborinfo'|'traceroute', last_seen)` (not in retention; clearing empties it), `rf_link_obs(observer, neighbor, snr, source, timestamp)` and `meta`. `telemetryTableNames` now has **15** entries. `rx` history is in `packet_rx` (hop_count 0, via_mqtt 0), not `rf_link_obs`. For 029: `GetRfLinkSnrSamples`, `GetRfLinkSnrRows`, `GetDirectRssiSamples` are not ported yet — add them next to `rfNeighbors` in `// MARK: - RF Links` using the private `read(default:_:)`. `MeshtasticProtocolService.tracerouteLinks` / `isNonRfSnr` and `firstSeen(nodeId:)` are reusable. Telemetry polling (`coordinator.telemetryPolling`) has deliberate limits (4 nodes, 60/30 min) — do not relax without the maintainer. LocalStats rates read the counters from `telemetry_samples` because `local_stats_telemetry` stores `payload_json`.
- **024**: everything lives in `MeshHessen/Services/Firmware/`. For 025/026: `FirmwareCatalogService().load()` → `resolveHardware(hwModel:pioEnv:in:)` (fallback `DeviceHardware.unknown(…, architectureGuess: guessArchitecture(…))`) → `FirmwareRetriever().download(release:hardware:kind:progress:)` returns a `FirmwareArtifact` (url, size, sha256). Gate every file with `FirmwareFileInspector.inspect(…)` and block on `hasErrors`. ESP32: `sendOtaRequest(mode:sha256:)`, wait for the `onClientNotification` confirmation (still not wired in `AppCoordinator`), then `UnifiedOta.startCommand` / `parse(line:)`. nRF52/RP2040: `enterDfuMode()`; 026 uses `DfuPackage(zipURL:)`. Manifest checksum failures are final (no Windows-style fallback). `StubFirmwareHTTPClient` in `FirmwareCatalogTests.swift` is reusable. Nothing calls the admin senders yet.
- **027**: math and builders in `MeshHessen/Services/Environment/` (`EnvironmentField.Grid` and `EnvironmentContours` are generic grid/iso-line helpers for 028/029). Data comes from `telemetry_samples` via `latestEnvironmentPerNode`; `.telemetrySampleDidInsert` now carries `insertedMetricsUserInfoKey`. Raster map: image overlays must be re-inserted after `applyBaseMap`; `updateDynamicOverlays` removes/re-adds lines, so filter by type. Vector map: custom layers must be re-added on `styledata` (`restoreEnvLayers` pattern); **028 must suspend 3D terrain while the environment heatmap image is active**, as Windows does. Not checked in the app: raster box placement, image flip, layer order with the real styles.

2026-11-13 (sixth wave) — plans 028 and 029 executed in parallel (029 without terrain, behind a `TriangulationTerrainSource` seam) and reviewed. Merged 028 (`0a5d2ea`, clean) then 029 (`3ee52cc`). Conflicts with 028 in `map.html` (`styledata` handler now runs `restoreEnvLayers(); restoreTriLayers(); applyTerrain()`), `VectorMeshMapView.swift`, `MapView.swift` and `TelemetryView.swift` — both sides kept. Coordinator integration: `TerrainService` conforms to `TriangulationTerrainSource` and the triangulation sheet passes `TerrainService.shared`; `TriangulationService`'s knife-edge/Fresnel helpers now forward to `LinkProfile` (one implementation). The combined result builds (`swift build`, `xcodebuild` Debug), the merged `map.html` script passes `node --check`, and `swift test` passes with 684 tests in 87 suites. Nothing was verified on hardware or in the running app.

Learnings that affect later plans:
- **028**: `TerrainService.shared.grid(covering: TerrainBounds) -> TerrainGrid?` (actor, 4-grid memory cache, tiles only via `VectorTileCacheService`, host from `MapTileSource.osm.meshHessenVectorStyleURL` + `/terrain/{z}/{x}/{y}`, single source `TerrainService.tileURLTemplate`). `TerrainGrid.sampler` is a `@Sendable` closure safe off the main actor. Link-profile verdict is three-level (clear: v ≤ −0.78; marginal: LOS free but Fresnel intruded; obstructed: v ≥ 0) — a flat 10 km path with 2.5 m antennas is "marginal", matching Windows' ~6 dB. 3D terrain is a vector-map-only toggle (`SettingsService.mapTerrain3D`); the drape is suspended while the environment heatmap is shown. Not checked in the app: terrain tiles through `WKWebView` + scheme handler, rotate/tilt and compass, heatmap with 3D on, chart look, offline/out-of-coverage behaviour.
- **029**: entry point is a triple-click on the "Analysis of the last N days" footer in `TelemetryView`. Estimates are never written to `AppState.nodes`, Core Data or `node_positions` (tested). New read-only queries in `// MARK: - RF Links`: `rfLinkSnrRows(since:)`, `rfLinkSnrSamples(observer:neighbor:myNodeId:since:)`, `directRssiSamples(nodeId:since:)`, `latestNoiseFloors()`. The Mac has no per-node precision bits, so every position counts as exact (prior error 0.2 km). Expert link budgets exist only as the `TriangulationNodeOverride` hook. Map layers live in the in-memory `TriangulationMapStore`. The noise test uses an exact port of .NET `Random(42)`. Not checked in the app: the triple-click, both map renderings, the ✕ removal and "Show on Map".

All plans except **025** and **026** are now done. Both flash real radios: unit tests cover only the protocol logic, and a person must test them on hardware before release. When they run: wire `protocol_.onClientNotification` in `AppCoordinator`, export a config backup first (023), then suppress `onLinkStale` / the heartbeat while flashing (008).

2026-11-13 (seventh wave) — plan 025 executed alone and reviewed with extra care (coordinator hooks, session run order and every exit path read line by line). Merged cleanly (`feat/025-firmware-wizard`). Coordinator fix `6d52f99`: in the UF2 path a cancel during the DFU settle delay ended update mode while the device was already rebooting into its bootloader; the link now counts as released as soon as `enter_dfu_mode` was sent. The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 731 tests in 94 suites. **No device was touched; a person must run the hardware checklist below before release.**

How it is wired:
- `AppCoordinator.beginFirmwareUpdate()` sets `firmwareUpdateInProgress`, cancels any pending reconnect and calls `protocol_.suspendLinkSupervision()` (stops heartbeat + watchdog). While the flag is set, `handleLinkStale()` returns early and `handleUnexpectedDisconnect()` does not auto-reconnect. `endFirmwareUpdate()` clears it and calls `resumeLinkSupervision()` (no-op without a live link). `disconnectForFirmwareUpdate()` / `reconnectAfterFirmwareUpdate(type:parameters:)` keep and reuse the last connection target. `protocol_.onClientNotification` is wired to `firmwareClientNotificationHandler`.
- `FirmwareUpdateSession.run()`: re-verify file (SHA-256, size, inspector) → config backup **while supervision is still on** (failure aborts before anything is sent) → `beginFirmwareUpdate()` → method. If the link was never released (refused, request not sent, cancelled early) update mode ends at the end of `run()`; after a release (or after `enter_dfu_mode` went out) it ends on Reconnect or when the wizard closes (`onDisappear` → `close()`).
- Single gate: `FirmwareUpdateSession.canStart` (artifact + inspection without errors + no red pre-flight row), checked by the button, the confirmation alert's action (`startConfirmed()`), and `run()`. UF2 re-verifies the file right before copying and requires an `NSOpenPanel` grant for a folder containing `INFO_UF2.TXT`.
- `Info.plist` gained `NSLocalNetworkUsageDescription`; entitlements unchanged. Backups are saved automatically to `<firmware cache>/backups/`.
- Deviation to confirm: the OTA beacon regex accepts lowercase hex, as the Windows C# does (the plan's test list said lowercase → false).

Hardware checklist (a person, before release):
1. ESP32 Wi-Fi OTA over serial/BLE on firmware ≥ 2.7.17, Mac on the same Wi-Fi: accept the local-network prompt; log shows "Firmware confirmed", beacon IP, ERASING, upload %, final OK; Reconnect shows the new version; no auto-reconnect during the transfer.
2. Same over TCP; block UDP to check the fallback to the known host after 8 s.
3. Hash refusal (`ERR Hash Rejected` / `ERR Hash Mismatch`): clear error, old firmware still runs.
4. Refusal while connected (Wi-Fi off on the device): refusal message, link stays up, debug log "Link supervision resumed".
5. UF2 on an nRF52 (RAK4631 or T-Echo) over USB: enter DFU → drive appears → picker opens at it → copy → drive vanishes → Reconnect (the serial port name may change).
6. UF2 on an RP2040 board, same as 5.
7. Recovery mode: not connected, device already in its bootloader; drive picked via "Choose Boot Drive…" or by re-plugging; local `.uf2` flashes.
8. Interrupted transfer: cancel / pull power mid-upload (ESP32) and mid-copy (UF2); the device stays recoverable; after closing the wizard, normal connect, auto-reconnect and heartbeat work again.
9. Close after the link was released without Reconnect: manual connect works, and a later link loss auto-reconnects.
10. Backup: JSON lands in the backups folder; a failed backup aborts with nothing sent.
11. Sandbox: writing to the picked boot drive and receiving UDP broadcasts on port 3232 both work. If either fails, report it — do not add a `/Volumes` exception.

Learnings for 026: replace the `.laterVersion` entries in `FirmwareWizardLogic.availableMethods`; add `.bleOta` / `.bleDfu` branches in `FirmwareUpdateSession.run()` (currently `methodNotSupported`); reuse `Esp32WifiOtaUpdater.perform`'s request/answer/release pattern and `classifyNotification` (add a mode parameter for "BLE"); go through `beginFirmwareUpdate` / `disconnectForFirmwareUpdate` / `endFirmwareUpdate`, never the heartbeat directly; keep every method behind `canStart`; `disconnect()` stops the shared `bleService`, so the loader/DFU scan probably needs its own CoreBluetooth central; heavy synchronous I/O belongs in `Task.detached` (the target uses approachable concurrency).

2026-11-13 (eighth wave) — plan 026 executed alone and reviewed with extra care (session branches, release points and exit paths read line by line). Merged cleanly (`feat/026-firmware-ble`). Coordinator fix: the Tools firmware description now names the Bluetooth methods. The combined result builds (`swift build`, `xcodebuild` Debug) and `swift test` passes with 791 tests in 101 suites. **No device was touched; a person must run the hardware checklist below before release.** With this, every plan in this folder is DONE.

How it is wired:
- Transports have no CoreBluetooth dependency (`Services/Firmware/Dfu/DfuProtocol.swift` with the `DfuGattLink` protocol, `LegacyDfuTransport`, `SecureDfuTransport`, `BleOtaTransport`) and are tested against a scripted `FakeDfuLink`. Only `BleGattLink.swift` imports CoreBluetooth; it uses its **own** `CBCentralManager`, never the mesh link's.
- **ESP32 BLE OTA**: `ota_request(.otaBle)` → wait ≤ 6 s for the ClientNotification. Refusal or request not sent → link not released, update mode ends at the end of `run()`. Confirmation, silence, or a cancel during the wait → `linkReleased = true` (`markRebootRequested`) → release the mesh link → find the loader (service UUID or former peripheral) → `OTA <size> <sha>` → chunked writes, one notification per chunk → final OK.
- **nRF52 DFU**: the mesh link is released (and counts as released) **before** the buttonless trigger (Secure FE59 first, then Legacy 1530) → bootloader scan → Secure or Legacy transfer with the Windows retry rules; ABORT/RESET is sent from a non-cancelled task on failure/cancel. Recovery mode (not connected) skips release and trigger.
- Both methods sit behind the same `canStart` gate and confirmation alert as 025; the file is re-read off the main actor and re-hashed right before sending. No entitlement or Info.plist change was needed.
- Deviations from Windows (deliberate fixes, all tested): Secure DFU ignores answers whose opcode does not match the pending command (a packet receipt at the end of an object looks like the checksum answer); sends PRN 1 to the device before resending lost bytes; refuses a device offset before the current object.
- **Known risk to check on hardware**: macOS exposes no MAC address, so the bootloader scan matches FE59/1530, a name containing "dfu", or the former peripheral identifier. A nearby foreign device in bootloader mode could be picked; the confirmation text warns about this.

Hardware checklist (a person, before release):
1. ESP32-S3 BLE OTA over BLE, firmware ≥ 2.7.17: log shows "Firmware confirmed: Rebooting to BLE OTA", loader found, ERASING, upload %, final OK; Reconnect shows the new version; no auto-reconnect during the transfer. Note whether macOS connects to the unbonded loader or the old pairing must be removed first.
2. Wrong hash / corrupted local file: `ERR Hash Mismatch` / Rejected gives a clear error, old firmware still runs.
3. Link drop mid-transfer (power off, out of range): clear error, device recovers after reset; normal connect, heartbeat and auto-reconnect work after closing the wizard.
4. Refusal while connected (e.g. no OTA partition): link stays up, debug log "Link supervision resumed".
5. nRF52 Legacy DFU (RAK4631 or T-Echo, older Adafruit bootloader): buttonless trigger reboots it, bootloader found (check name and RSSI in the log), "Bootloader protocol: Legacy DFU", erase wait, upload, validate, reboot. Check the packet size used is a multiple of 4.
6. nRF52 Secure DFU (FE59 bootloader, if available).
7. Resume after a drop: Secure resumes from SELECT; Legacy retries the whole session with PRN 5.
8. Device already in its bootloader, wizard opened without a connection: recovery DFU with a local `-ota.zip`.
9. Cancel mid-transfer: RESET/ABORT in the log, bootloader stays in DFU, a second run works without a power cycle.
10. Stale session: cancel during the erase, run again; expect "interrupted session — resetting it".
11. Two devices in bootloader mode nearby: the right one is chosen — report if not.
12. Hardware flagged `requiresBootloaderUpgradeForOta` shows the warning on the device and pre-flight pages.
13. After each Bluetooth update: Reconnect works or the re-pair hint applies; manual connect works after closing without Reconnect.

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
