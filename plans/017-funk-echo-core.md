# Plan 017: "Funk-Echo" — the client shows who is requesting data from this node

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Views/MeshStatusIndicatorsView.swift MeshHessen/Services/SettingsService.swift MeshHessen/Models/SystemSettings.swift MeshHessen/Models/ChannelInfo.swift`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: LOW (additive)
- **Depends on**: plans/005-telemetry-data-correctness.md (request detection hook)
- **Category**: direction (feature parity with Windows 1.7.0, "Wer funkt mich an?")
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

When another station asks this node for its NodeInfo, position, telemetry, a traceroute or sends an admin packet, the firmware answers automatically and the user never notices. Windows 1.7.0 made these requests visible: a radar icon in the status bar pulses, a journal lists who asked for what and when, and 7-day statistics show the "most curious" node. It is one of the most visible Windows-only features. This plan delivers the core (detection, storage, indicator, journal + statistics window, settings, kiosk lock, dashboard metric); plan 018 adds the sonar view, drill-down, map route and airtime estimate.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Models/RequestEchoModels.cs` (classifier ~58–131, expectation ~18–37), `MeshhessenClient.Tests/RequestEchoTests.cs`, `MeshhessenClient/Services/TelemetryDatabaseService.cs` (table ~156–170, `UpsertRequestEcho` ~1450–1504, journal/stats queries, `QueryFunkEchoSeries` ~1597–1635), `MeshhessenClient/MainWindow.FunkEcho.cs`, `MeshhessenClient/RequestEchoWindow.cs` (journal ~152–420, stats ~823–930), `MeshhessenClient/Resources/Strings.de.xaml` / `Strings.en.xaml` (keys `StrFunkEcho…` — take the message texts from there).
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- Portnum dispatch: `handleMeshPacket` in `MeshHessen/Services/MeshtasticProtocolService.swift` (~650); `isInitializing` is true during the connect backlog (set false at "// 9. Finish init", ~305). After plan 005 there is `static func isIncomingRequest(_:to:myNodeId:)` used by the traceroute and telemetry handlers.
- `MeshHessen/Services/TelemetryDatabaseService.swift`: SQLite wrapper (`enqueueWrite { service, db in service.run(sql, bindings:…, on: db) }`), schema block ~140–250, `telemetryTableNames` (~57) drives retention, `getTimeSeries` (~1104) has a special branch for the packet-count metric (search `isPacketCount`).
- `MeshHessen/Views/MeshStatusIndicatorsView.swift`: an `HStack` of `statusIndicator(symbol:color:title:detail:)` items (Signal, Direct Neighbors, Path Stability, Mesh Health, Weather Sensors).
- `MeshHessen/Models/SystemSettings.swift` `KioskFeatureMask` (~147): bits 0…10 used (`quickConfiguration = 1 << 10`), with `allCases` and localized names.
- `MeshHessen/Models/ChannelInfo.swift` has no position-precision field (generated: `channel.settings.moduleSettings.positionPrecision`).
- Notifications: an existing `SystemNotificationService` is used for telemetry alarms in `MeshHessen/Services/TelemetryDashboardStore.swift` (~239).

Classification rules (port from `RequestEchoClassifier.Classify`): a packet counts only if `to == myNodeId`, `from != 0`, `from != myNodeId`, it is decoded, and `data.requestID == 0`. Portnum NodeInfo(4)/Position(3)/Telemetry(67)/Traceroute(70) additionally require `wantResponse`; Admin(6) counts with or without it. Telemetry requests carry which variant is wanted (device / environment (soil-water counts as environment) / air quality / power / local stats / host / health) → stored as `detail`. Traceroute requests carry the route so far (`RouteDiscovery.route`) → stored. Hops = nil if `hopStart == 0` or `hopLimit > hopStart`, else `hopStart - hopLimit`. Skipped while `isInitializing`.

Reply expectation (`RequestEchoExpectation.Compute`): NodeInfo, Traceroute → `yes`; Position → `no-pos` when we have no own position, `prec:<bits>` when the request's channel (index ≤ 7) has position precision 1…31, else `yes`; Telemetry device/local stats → `yes`, other telemetry → `sensor`; Admin → `auth`.

Storage (`request_echo`): `id, node_id, req_type TEXT, first_ts, last_ts, count DEFAULT 1, hops NULL, via_mqtt, route TEXT ('!id,!id'), detail TEXT, expected TEXT`; indexes `(last_ts)` and `(node_id, req_type, last_ts)`. Burst aggregation: a new event with the same (node, type, detail) whose latest row has `last_ts >= ts - 10 min` increments `count` and updates `last_ts`; otherwise a new row.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter RequestEcho` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Models/RequestEchoModels.swift` (create), `MeshHessen/Views/RequestEchoView.swift` (create), `MeshHessen/Views/RequestEchoIndicator.swift` (create), the six files in the drift check, `MeshHessen/Models/TelemetryPersistenceModels.swift` (one metric), `MeshHessen/Views/SettingsView.swift`, `MeshHessen/MeshHessenApp.swift` (window scene), `MeshHessen/AppState.swift` (unread counter + last event), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/RequestEchoTests.swift` (create).

**Out of scope** (plan 018): sonar radar, per-station drill-down, request route on the map, airtime estimate. Also out: any claim that the node "answered" — the firmware's replies are invisible to the client; show only "request detected" and the expectation.

## Git workflow

Branch `feat/017-funk-echo-core`. Conventional commits per step. Do not push.

## Steps

### Step 1: Models + classifier (pure)
`RequestEchoModels.swift`: `enum RequestEchoType: String, CaseIterable { nodeInfo, position, telemetry, traceroute, admin }`, `struct RequestEchoEvent`, `enum RequestEchoClassifier { static func classify(myNodeId: UInt32, packet: Meshtastic_MeshPacket) -> RequestEchoEvent? }`, `enum RequestEchoExpectation { static func compute(...) -> String }`. Port all cases of `RequestEchoTests.cs`.

**Verify**: `swift test --filter RequestEcho` → pass.

### Step 2: Storage
Add the table, indexes, `upsertRequestEcho(_:expected:)`, `requestEchoJournal(since:limit:)` (default limit 500, newest first), `requestEchoStats(days:)` (totals per type, per telemetry detail, top-5 nodes, distinct stations, trace count) and add the table to retention (it uses `last_ts` — check how retention chooses the timestamp column; if it requires a column literally named `timestamp`, add a small explicit `DELETE FROM request_echo WHERE last_ts < ?` next to the generic cleanup). Tests for burst aggregation: two events 5 min apart → one row with count 2; 11 min apart → two rows; different `detail` → two rows.

### Step 3: Hook into the protocol service
At the top of the `.decoded` handling in `handleMeshPacket`, when `!isInitializing` and the feature is enabled: `if let event = RequestEchoClassifier.classify(...)` → compute expectation (own position from the own node; precision from `ChannelInfo.positionPrecision`, a new `Int` field filled in `channelInfo(from:)`), persist, publish to `AppState` (`requestEchoUnread += 1`, `lastRequestEcho = event`). Replace plan 005's `isIncomingRequest` early-returns in the traceroute/telemetry handlers by the classifier result if that is simpler; behaviour must stay "requests are not stored as results".

### Step 4: Settings + kiosk
`SettingsService`: `funkEchoEnabled` (default true), `funkEchoTone` (`"casual"`/`"factual"`, default casual), `funkEchoNotifications` (default false), `funkEchoQuiet` (default false) using the existing property pattern; controls in `SettingsView.swift`. `KioskFeatureMask`: `static let funkEcho = Self(rawValue: 1 << 11)`, added to `allCases` and to the localized-name switch; honour it where the indicator opens the window.

### Step 5: Indicator
`RequestEchoIndicator`: an antenna symbol (`antenna.radiowaves.left.and.right`) with an unread badge (cap "99+"); on each new event (unless quiet) a ring pulses outward — scale 0.6→2.1, opacity 0.9→0 over 0.85 s, twice for traceroute — coloured by type (NodeInfo `#8B73D8`, Position `#DB9A44`, Telemetry `#20C997`, Traceroute `#428ECC`, Admin `#F04C4C`), plus a popover for 5 s with the message text (casual or factual tone). Context menu: "Quiet mode" toggle. Click: reset unread, `openWindow(id: "request-echo")`. Add it to `MeshStatusIndicatorsView` after Mesh Health, hidden when the feature is disabled. If `funkEchoNotifications` is on and the app is not active, post a user notification through the existing notification service.

### Step 6: Journal + statistics window
`RequestEchoView` (new `Window` scene `id: "request-echo"` in `MeshHessenApp.swift`, following the existing secondary-window pattern): toolbar filters — range 24 h / 7 d / 30 d (default 7 d), type, search (short name / long name / `!hex`); two tabs:
- **Journal**: rows grouped by day (Today / Yesterday / date) showing time, type icon, station name, `×n` for bursts, source badge (direct / n hops / MQTT), for traceroutes "via A → B", and the expectation text ("reply expected", "reply expected (±2.9 km)" for `prec:` — compute the radius from precision bits as Windows does, "no reply (no position)", "depends on sensors", "only with authorisation"). Context menu: Node info, Show on map (must also switch to the map tab — use `coordinator.router.navigateToNodeOnMap(nodeNum:)`), Send DM.
- **Statistics**: tiles (requests / stations / traces), horizontal bars per type with an indented telemetry-detail breakdown, "Most curious node".
Reload on new events, debounced 600 ms.

### Step 7: Dashboard metric
`TelemetrySeriesMetric`: `case funkEcho = "funk_echo"` (title "Funk-Echo (requests to us/h)", range 0–20). In `getTimeSeries` add a branch next to the packet-count special case: `SELECT (CAST(last_ts/3600 AS INTEGER))*3600 AS bucket, node_id, SUM(count) FROM request_echo WHERE last_ts >= ? GROUP BY bucket, node_id`.

**Verify (after each step)**: `swift build` exit 0; at the end `swift test` → all pass and the app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 including `RequestEcho` suites (classifier, expectation, aggregation)
- [ ] xcodebuild Debug build succeeds
- [ ] `grep -n "request_echo" MeshHessen/Services/TelemetryDatabaseService.swift` shows table + queries
- [ ] No UI text claims a request was "answered"
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- Plan 005's request hook is absent and incoming traceroute requests are still stored as results.
- A window scene cannot be added following the existing pattern (e.g. scenes are generated elsewhere).
- The classifier tests ported from Windows disagree with the rules listed here — the C# tests win; report the difference.

## Maintenance notes

- The connect backlog must stay excluded (`isInitializing`), otherwise every reconnect floods the journal.
- Plan 018 extends `RequestEchoView` with further tabs; keep its tab container simple.
- Not verified on air. Reviewer: request position/telemetry/traceroute from a second node and watch indicator + journal.
