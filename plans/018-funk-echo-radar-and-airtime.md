# Plan 018: Funk-Echo gets the sonar radar, per-station drill-down, request route on the map and a reply-airtime estimate

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git log --oneline -1 -- MeshHessen/Views/RequestEchoView.swift` must show a commit (plan 017 done). If the file does not exist: STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (additive)
- **Depends on**: plans/017-funk-echo-core.md (hard)
- **Category**: direction (feature parity with Windows 1.7.0 "V3")
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows complements the Funk-Echo journal with a retro sonar view (stations placed by how often they ask), a per-station hourly breakdown, drawing a traceroute request's path on the map, and an estimate of how much airtime the node's automatic replies cost. These are the "delight" parts of the feature and the airtime number is practically useful for duty-cycle awareness.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI (Canvas, TimelineView, Swift Charts available); tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/LoRaAirtime.cs`, `MeshhessenClient.Tests/LoRaAirtimeTests.cs`, `MeshhessenClient/RequestEchoWindow.cs` (radar ~423–710, drill-down ~743–820, airtime tile in stats), `MeshhessenClient/MainWindow.FunkEcho.cs` (`ShowRequestRouteOnMap` ~205–223).
- From plan 017: `MeshHessen/Models/RequestEchoModels.swift`, `MeshHessen/Views/RequestEchoView.swift`, DB functions `requestEchoJournal` / `requestEchoStats`, dashboard metric `funk_echo`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Facts to port

**LoRa airtime** (`LoRaAirtime.cs`): per modem preset (SF, bandwidth kHz, coding-rate denominator):
LongFast 11/250/5 · LongSlow 12/125/8 · LongModerate 11/125/8 · LongTurbo 11/500/8 · MediumSlow 10/250/5 · MediumFast 9/250/5 · MediumTurbo 9/500/5 · ShortSlow 8/250/5 · ShortFast 7/250/5 · ShortTurbo 7/500/5 · LiteFast 9/125/5 · LiteSlow 10/125/5 · NarrowFast 7/62.5/6 · NarrowSlow 8/62.5/6 · TinyFast 7/15.6/5 · TinySlow 8/15.6/6.
Semtech formula: `tSym = 2^SF / BW` (ms, BW in kHz); `DE = 1` if `tSym > 16`; preamble = `(16 + 4.25) * tSym`; payload symbols = `8 + max(ceil((8*PL - 4*SF + 44) / (4*(SF - 2*DE))) * CR, 0)` with `CR` = the coding-rate denominator (5…8); airtime = preamble + payloadSymbols * tSym. Packet length `PL` = 16-byte header + payload: NodeInfo 50, Position 30, Telemetry 32 (LocalStats 45), Traceroute `12 + 6*max(hops+1, 1)`, other 30. Only requests with expectation `yes` or `prec:*` are counted. **Port the exact expression from the C# file and make the ported C# tests pass — they are the truth if this summary differs.**

**Radar geometry** (`RequestEchoWindow.cs`): colours bright `#53FFB0`, mid `#20C997`, dim `#176B4E`, grid `#14523C` on black; sweep wedge 42° rotating once per 5 s; per station `frac = ln(total+1) / ln(maxTotal+1)`, radius = `maxR * (0.92 - 0.55*frac)`, angle = `((nodeId &* 2654435761) % 3600) / 3600 * 2π` (use 64-bit arithmetic, then modulo), dot radius `5 + 6*frac`, glow `10 + 8*frac`. Live ping: a ring travels from the station to the centre and back in 1 s, then the station flashes for 0.45 s.

**Request route**: stored route of a traceroute request, reversed, with the requester appended → a `TracerouteResult` with forward route and no SNR values, shown with the existing traceroute map overlay; then switch to the map tab.

## Current state

- The existing traceroute overlay and how a `TracerouteResult` is put on the map: read `MeshHessen/Views/TracerouteSheet.swift` (the "show on map" action) and `MeshHessen/Models/TracerouteResult.swift` initialisers.
- Modem preset of the local node: `receivedConfigs[.lora]` in `MeshtasticProtocolService.swift` (~1289); if plan 009/010 added a public accessor use it, otherwise add `var currentModemPreset: <generated ModemPreset>?`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter LoRaAirtime` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Services/LoRaAirtime.swift` (create), `MeshHessen/Views/RequestEchoRadarView.swift` (create), `MeshHessen/Views/RequestEchoView.swift`, `MeshHessen/Services/MeshtasticProtocolService.swift` (preset accessor only), `MeshHessen/Services/TelemetryDatabaseService.swift` (one hourly-per-node query if missing), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/LoRaAirtimeTests.swift` (create).

**Out of scope**: an "answer observed" heuristic (Windows deliberately left it out); sound effects.

## Git workflow

Branch `feat/018-funk-echo-radar`. Conventional commits per step. Do not push.

## Steps

### Step 1: `LoRaAirtime` (pure) + tests
`enum LoRaAirtime { static func parameters(for preset:) -> (sf: Int, bwKHz: Double, cr: Int)?; static func airtimeMs(payloadBytes: Int, sf: Int, bwKHz: Double, cr: Int) -> Double; static func replyPayloadBytes(type: RequestEchoType, detail: String?, hops: Int?) -> Int }`. Port `LoRaAirtimeTests.cs`.

**Verify**: `swift test --filter LoRaAirtime` → pass.

### Step 2: Airtime tile
In the statistics tab add a tile "Estimated reply airtime": sum over journal rows in range with expectation `yes`/`prec:*` of `count * airtime(type)`, formatted in seconds; hidden when the preset is unknown.

### Step 3: Radar tab
`RequestEchoRadarView`: `TimelineView(.animation)` + `Canvas` drawing rings, crosshair, rotating sweep and stations per the geometry above from `requestEchoStats`' per-node totals (respecting the window's filters); hover tooltip with name and per-type counts; click selects a station. On a live event for a visible station, play the ping.

### Step 4: Drill-down
Below the radar, for the selected station: Swift Charts `BarMark` of requests per hour (query: hourly buckets for one node — reuse the `funk_echo` series query from plan 017 filtered by node) and a per-type / telemetry-detail breakdown. Context menu like the journal's (Node info / Show on map / Send DM).

### Step 5: Request route on the map
Journal and radar context menu item "Show request path on map" for traceroute rows with a stored route: build the `TracerouteResult` as described, add it through the same call the traceroute sheet uses, and navigate to the map tab.

**Verify**: `swift build` exit 0 after each step; app build succeeds at the end; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 including `LoRaAirtime` suite; xcodebuild Debug build succeeds
- [ ] `RequestEchoView` has three tabs (Journal, Statistics, Radar)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `RequestEchoView.swift` or the stats query from plan 017 is missing.
- A `TracerouteResult` without SNR values cannot be shown by the existing overlay (crash/assert) — report rather than changing the overlay's data model.

## Maintenance notes

- When new modem presets appear upstream, extend the table; unknown presets must return nil (tile hidden), never a guess.
- The animation runs only while the radar tab is visible — keep the `TimelineView` inside that tab.
