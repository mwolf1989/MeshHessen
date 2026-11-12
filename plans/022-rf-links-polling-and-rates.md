# Plan 022: Real RF neighbour links are collected, telemetry can be polled on a schedule, and LocalStats counters become rates

> **Executor instructions**: Follow this plan step by step. The three parts (A, B, C) are independent — finish and commit one before starting the next. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Views/TelemetryView.swift MeshHessen/Models/TelemetryPersistenceModels.swift MeshHessen/Views/NodeInfoSheet.swift`

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: LOW–MED
- **Depends on**: plans/005-telemetry-data-correctness.md
- **Category**: direction (feature parity with Windows 1.6.4.6)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows 1.6.4.6 builds a picture of who hears whom over RF from three evidence sources (own direct reception, NeighborInfo packets, traceroute segments), can poll selected nodes for telemetry on a schedule, and turns the monotonically increasing LocalStats packet counters into "packets per hour" series. The Mac only knows its own direct contacts, ignores NeighborInfo content and traceroute return paths, has no polling, and shows raw counters. Plan 029 (triangulation) needs the RF link data.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing; telemetry DB tests in `TelemetryDashboardParityTests.swift` / `PersistenceTests.swift`).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/TelemetryDatabaseService.cs` (`rf_links`/`rf_link_obs` schema, `UpsertRfLink`, `GetRfNeighbors` ~737, cleanup ~196–201, `GetLocalStatsRateSeries` ~505–540, `GetFirstSeen` ~646), `MeshhessenClient/Services/MeshtasticProtocolService.cs` (rx source ~1375–1383, NeighborInfo ~2231–2253, traceroute segments ~2283–2300), `MeshhessenClient/Services/TelemetryPollingService.cs`, `MeshhessenClient.Tests/RfLinkTests.cs`, `MeshhessenClient.Tests/LocalStatsRateTests.cs`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `MeshHessen/Services/TelemetryDatabaseService.swift`: SQLite wrapper (`enqueueWrite { service, db in service.run(sql, bindings:…, on: db) }`; schema ~140–250; `telemetryTableNames` ~57); `getDirectNeighborContacts` (~503–545) returns own 0-hop contacts; `local_stats_telemetry` table (~231–239); `getTimeSeries` (~1104).
- `MeshHessen/Services/MeshtasticProtocolService.swift`: `handleNeighborInfoPacket` (~2503–2544) only counts and logs neighbours (its comment claims no generated message exists — `Meshtastic_NeighborInfo` / `Meshtastic_Neighbor` do exist in `MeshHessen/Generated/mesh.pb.swift`); `handleTraceroutePacket` (~1618) uses `route`/`snrTowards` but ignores `routeBack`/`snrBack`; the direct-RF bookkeeping is in `handleMeshPacket` (~596–635, `isDirectRF`); `requestNodeInfo` (~3000) sends info/telemetry requests of a `NodeInfoRequestType`.
- `MeshHessen/Views/TelemetryView.swift` (~120–190): neighbour list from own direct contacts.
- `MeshHessen/Models/TelemetryPersistenceModels.swift`: `TelemetrySeriesMetric` with `local_*` metrics (~80–92).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter RfLink` / `--filter LocalStatsRate` / `--filter TelemetryPolling` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the five files in the drift check, `MeshHessen/Services/TelemetryPollingService.swift` (create), `MeshHessen/Views/TelemetryPollingSheet.swift` (create), `MeshHessen/Views/TelemetryDashboardView.swift` (one button), `MeshHessen/AppCoordinator.swift` (start/stop polling), `MeshHessen/Localizable.xcstrings`, three new test files.

**Out of scope**: map drawing of links, triangulation (plan 029), link elevation profile (plan 028).

## Git workflow

Branch `feat/022-rf-links-polling-rates`. One commit per part. Do not push.

## Part A — RF links

1. Schema:
   ```sql
   CREATE TABLE IF NOT EXISTS rf_links (observer INTEGER NOT NULL, neighbor INTEGER NOT NULL, snr REAL, source TEXT NOT NULL, last_seen REAL NOT NULL, PRIMARY KEY (observer, neighbor, source));
   CREATE TABLE IF NOT EXISTS rf_link_obs (observer INTEGER NOT NULL, neighbor INTEGER NOT NULL, snr REAL NOT NULL, source TEXT NOT NULL, timestamp REAL NOT NULL);
   ```
   plus a `meta` key `rf_links_started` (first-insert time; create a tiny key/value table if none exists). `rf_link_obs` joins retention; `rf_links` does not.
2. `upsertRfLink(observer:neighbor:snr:source:timestamp:)`: SNR `0` is stored as NULL; sources `"rx"`, `"neighborinfo"`, `"traceroute"`; `rf_link_obs` rows only for non-`rx` sources with a real SNR.
3. Feed it: (a) own direct reception — in `handleMeshPacket` where `isDirectRF` is true: observer = own node, neighbor = `packet.from`; (b) `handleNeighborInfoPacket` — decode `Meshtastic_NeighborInfo`, for each neighbour `upsert(observer: info.nodeID, neighbor: n.nodeID, snr: n.snr)`; (c) `handleTraceroutePacket` (responses only) — for the forward path `[source, route…, destination]` with `snrTowards`, and the return path `[destination, routeBack…, source]` with `snrBack`: for each adjacent pair the **receiver** (`path[i+1]`) is the observer, the sender the neighbour, SNR = raw / 4; skip segments whose raw SNR is `<= -128` or `0`. Port the pairing logic from the C# and its tests (`RfLinkTests.cs`) — put it in a pure `static func tracerouteLinks(...) -> [(observer, neighbor, snr)]`.
4. `rfNeighbors(of nodeId:) async -> [RfNeighbor]` (both directions: `snrIn`, `snrOut`, sources, last seen).
5. `TelemetryView`: use RF neighbours when there are ≥ 3 links, or 1–2 links once collection has run ≥ 7 days (`rf_links_started`); otherwise the current direct-contact list. Show source badges and both SNR directions.
6. `firstSeen(nodeId:)` = `MIN(timestamp)` from `packet_rx`; show "First seen" next to "Last heard" in `NodeInfoSheet.swift`.

## Part B — LocalStats rates

Add metrics `localRxPerHour = "local_rx_pph"`, `localTxPerHour = "local_tx_pph"`, `localRxBadPerHour = "local_rx_bad_pph"`, `localRxDupePerHour = "local_rx_dupe_pph"`, `localTxRelayPerHour = "local_tx_relay_pph"` and a `getTimeSeries` branch computing, per node and consecutive sample pair, `rate = Δcounter / Δhours`, kept only if `1/60 <= Δhours <= 24` and `Δcounter >= 0` (a reboot resets counters → skip). Pure helper `static func counterRates(_ samples: [(Date, Double)]) -> [(Date, Double)]`; port `LocalStatsRateTests.cs`. Map each metric to its counter column in `local_stats_telemetry` (read the table definition for the column names).

## Part C — Telemetry polling

`TelemetryPollingService` (`@Observable @MainActor`): plan = `enabled` + entries `{ nodeId, type: NodeInfoRequestType, intervalMinutes, lastSentUtc }`, persisted as JSON `telemetry_polling.json` in the app's Application Support folder (same folder `AppLogger`/`MessageLogger` use). Limits (enforce in the model, test them): at most 4 distinct nodes; minimum interval 60 min for local stats, 30 min for other types; at most one request per minute overall. A 60-second `Task` loop, running only while connected (start/stop from `AppCoordinator` on connect/disconnect), picks the most overdue entry and calls the existing request function. `TelemetryPollingSheet`: list/add/remove entries, enable toggle; opened from a button in `TelemetryDashboardView`. Pure scheduling function `nextDue(entries:now:lastRequestAt:) -> Entry?` with tests.

## Test plan

- `RfLinkTests.swift`: ported pairing tests; SNR 0 → NULL; `rfNeighbors` merges directions.
- `LocalStatsRateTests.swift`: ported rate tests (normal delta, reboot reset skipped, gap > 24 h skipped, gap < 1 min skipped).
- `TelemetryPollingTests.swift`: limits enforced; `nextDue` respects intervals and the one-per-minute rule; JSON round trip.

**Verify**: each filtered suite passes; `swift test` → all pass; app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 with the three new suites; xcodebuild Debug build succeeds
- [ ] `grep -n "rf_links" MeshHessen/Services/TelemetryDatabaseService.swift` shows schema + upsert + query
- [ ] `handleNeighborInfoPacket` decodes `Meshtastic_NeighborInfo` (stale comment removed)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `Meshtastic_NeighborInfo` is not in the generated code.
- `handleTraceroutePacket` cannot tell requests from responses (plan 005 not done).
- The polling request function needs a session key or parameters that are not available outside a view.

## Maintenance notes

- Polling costs airtime on the mesh; the limits are deliberate — do not relax them without the maintainer.
- `rf_links` is keyed by (observer, neighbor, source); plan 029 reads `rf_link_obs` for signal statistics.
