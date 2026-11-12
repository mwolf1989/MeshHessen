# Plan 005: Signal series contain only direct-RF measurements, requests are not stored as results, and dashboard charts scale to real data

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Views/TelemetryDashboardWidgetViews.swift MeshHessen/Models/TracerouteResult.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Four independent data-quality bugs that Windows fixed in 1.6.4.6/1.7.0 are still in the Mac client:
1. SNR/RSSI time series include multi-hop and MQTT packets. `rx_snr`/`rx_rssi` describe only the **last** radio hop, so a relayed packet records the relay's signal under the original sender's name (and MQTT packets record 0).
2. An incoming traceroute *request* addressed to us is saved as if it were a traceroute result; an incoming telemetry *request* (empty payload) is treated as telemetry data.
3. Dashboard charts pin their axis to the metric's theoretical range (e.g. RSSI squeezed into a corner, outliers clipped); the heatmap colour scale has the same problem.
4. The gauge is tinted red→orange→green, which is wrong for "high is bad" metrics such as channel utilisation; candlesticks flip colour on noise.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI, Swift Charts; tests in `Tests/MeshHessenTests/` (Swift Testing). Baseline: `swift test` → 261 tests pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`).
- Conventions: 4-space indent; `AppLogger.shared.log(...)`; never edit `MeshHessen/Generated/`.

## Current state

`MeshHessen/Services/TelemetryDatabaseService.swift` `insertPacketRx` (~449) — always stores signal samples:
```swift
let storedSamples: [TelemetrySeriesMetric: Double] = [
    .snr: Double(snr), .rssi: Double(rssi),
]
return inserted && service.insertSamples(nodeId: nodeId, timestamp: ts, variant: "packet", values: storedSamples, isDay: isDay, on: db)
```
The function already receives `hopCount: Int` and `viaMqtt: Bool`. A one-time legacy migration nearby (~346–360) copies old rows the same way.

`MeshHessen/Services/MeshtasticProtocolService.swift`:
- `handleTraceroutePacket` (~1618) decodes `RouteDiscovery` and stores a `TracerouteResult` without checking whether the packet is a request.
- `handleTelemetry` (~2643) has no request check.
- Meshtastic semantics: a **request** has `data.wantResponse == true` and `data.requestID == 0`; a **response** carries `data.requestID != 0`.

`MeshHessen/Views/TelemetryDashboardWidgetViews.swift`:
```swift
.gaugeStyle(.accessoryCircular)
.tint(Gradient(colors: [.red, .orange, .green]))          // ~line 422
...
private struct DashboardMetricScale: ViewModifier {        // ~line 855
    if let range = widget.effectiveDisplayRange { content.chartYScale(domain: range) } else { content }
private struct DashboardHistogramScale: ViewModifier {     // ~line 868
    if let range = widget.effectiveDisplayRange { content.chartXScale(domain: range) } else { content }
```
`effectiveDisplayRange` (in `MeshHessen/Models/TelemetryDashboardModels.swift`) returns the user's `displayMinimum/displayMaximum` if set, otherwise the metric's suggested span. The heatmap colour bounds (~487–493) and candlestick colours (`close >= open ? green : red`, ~557/564) are in the same file.

`MeshHessen/Models/TracerouteResult.swift` `decodedSNR` (~128) treats only `-128` as "no measurement"; Windows also treats `0` as non-RF (`IsNonRfSnr(s) = s <= -128 || s == 0`).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter TelemetryDataCorrectness` | all pass |
| All tests | `swift test` | all pass (≥ 261) |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the four files in the drift check, `MeshHessen/Models/TelemetryDashboardModels.swift` (one helper), `Tests/MeshHessenTests/TelemetryDataCorrectnessTests.swift` (create).

**Out of scope**: warn/alarm zones (plan 019), chart zoom, Funk-Echo journal (plan 017 — this plan only stops the misclassification), deleting historical samples from users' databases.

## Git workflow

Branch `fix/005-telemetry-data-correctness`. One commit per step, conventional messages. Do not push.

## Steps

### Step 1: Direct-RF filter for signal samples
In `insertPacketRx`, build `storedSamples` only when `hopCount == 0 && !viaMqtt`, and inside that include `.snr` only if `snr != 0` and `.rssi` only if `rssi != 0`. When the dictionary is empty skip `insertSamples` (still insert the `packet_rx` row and still publish `.packetCount`). Apply the same condition to the values passed to `publishFreshTelemetry`. Extract the decision into `static func signalSamples(snr: Float, rssi: Int32, hopCount: Int, viaMqtt: Bool) -> [TelemetrySeriesMetric: Double]` so it is testable. Leave the legacy migration alone.

**Verify**: `swift build` exit 0.

### Step 2: Requests are not results
Add to `MeshtasticProtocolService`:
```swift
static func isIncomingRequest(_ data: Meshtastic_Data, to: UInt32, myNodeId: UInt32) -> Bool {
    myNodeId != 0 && to == myNodeId && data.wantResponse && data.requestID == 0
}
```
At the top of `handleTraceroutePacket` and `handleTelemetry`: `if Self.isIncomingRequest(data, to: packet.to, myNodeId: myNodeId) { log at debug level; return }`. Do not change anything else in those handlers.

### Step 3: Traceroute SNR 0 means "no RF measurement"
In `TracerouteResult.decodedSNR` treat raw `0` like `-128` (nil). Check its call sites (`grep -n decodedSNR MeshHessen -r`) so UI code showing "0.0 dB" now shows the existing "unknown" representation. In `insertTracerouteHops` (`TelemetryDatabaseService.swift`, ~942) store NULL instead of 0 for such hops if the column is nullable; if it is `NOT NULL`, leave storage unchanged.

### Step 4: Chart scales follow the data
- In `TelemetryDashboardModels.swift` add `var explicitDisplayRange: ClosedRange<Double>?` (non-nil only when the user set `displayMinimum` and/or `displayMaximum`).
- `DashboardMetricScale` / `DashboardHistogramScale`: apply a domain only for `explicitDisplayRange`; otherwise let Swift Charts auto-scale.
- Heatmap: colour bounds = `explicitDisplayRange` if set, else min/max of the values actually drawn (guard `min == max`).
- Gauge: replace the gradient with a single neutral tint (`.tint(.accentColor)`); keep the gauge's own min/max labels as they are.
- Candlestick: when `abs(close - open) < 0.02 * max(abs(high - low), .leastNonzeroMagnitude)` draw in `.secondary` grey instead of green/red.

**Verify**: xcodebuild Debug build → `** BUILD SUCCEEDED **`.

## Test plan

`TelemetryDataCorrectnessTests.swift`:
- `signalSamples`: hop 0 / not MQTT / snr 5.5 / rssi −90 → both keys; hop 2 → empty; viaMqtt → empty; snr 0 with rssi −90 → only `.rssi`.
- `isIncomingRequest`: wantResponse + requestID 0 + to == me → true; requestID 7 → false; to == other → false; myNodeId 0 → false.
- `decodedSNR`: raw 0 → nil, raw −128 → nil, raw 20 → 5.0 (check the existing scaling in the file and assert accordingly).
- `explicitDisplayRange`: nil when neither bound is set; a range when both are set.

**Verify**: `swift test --filter TelemetryDataCorrectness` → pass; `swift test` → all pass. If an existing test asserted the old behaviour (e.g. in `TelemetryDashboardParityTests.swift` or `TracerouteHistoryParityTests.swift`), update that assertion and list it in your report.

## Done criteria

- [ ] `swift test` exits 0 including the new suite
- [ ] `grep -n "Gradient(colors: \[.red, .orange, .green\])" MeshHessen/Views/TelemetryDashboardWidgetViews.swift` → no matches
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `effectiveDisplayRange` is used by non-chart logic (alarms) in a way that changing chart modifiers would alter — do not change `effectiveDisplayRange` itself.
- More than three existing tests fail because of Step 1–3.

## Maintenance notes

- Existing databases keep old polluted SNR/RSSI samples; they age out through retention.
- Plan 017 (Funk-Echo) hooks into the same request detection and will replace `isIncomingRequest` call sites with its classifier.
