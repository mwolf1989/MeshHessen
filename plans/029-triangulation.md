# Plan 029: A node's position can be estimated from RF neighbour signals (triangulation easter egg)

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `grep -n "rf_link_obs\|node_positions" MeshHessen/Services/TelemetryDatabaseService.swift | head` must show both tables (plans 004 and 022), and `ls MeshHessen/Services/TerrainService.swift` should exist (plan 028; optional — see Step 4). If the tables are missing: STOP.

## Status

- **Priority**: P3 (lowest; an easter egg on Windows too)
- **Effort**: L
- **Risk**: LOW (additive, hidden entry point)
- **Depends on**: plans/004-node-position-retention.md (hard), plans/022-rf-links-polling-and-rates.md (hard), plans/028-terrain-link-profile-3d.md (soft)
- **Category**: direction (feature parity with Windows 1.7.0)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows 1.7.0 hides a "triangulate position" tool behind a triple-click in the telemetry window: it estimates where a node without GPS is located from the signal strength its RF neighbours measured, draws distance rings around the anchors and an uncertainty region on the map, and self-calibrates its path-loss model from links where both ends have GPS. It is explicitly presented as a rough estimate. It completes parity with the Windows RF analysis tools.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY, **authoritative** — the service is pure math; port it and its tests 1:1): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/TriangulationService.cs`, `MeshhessenClient.Tests/TriangulationTests.cs`; orchestration `MeshhessenClient/MainWindow.xaml.cs` (~4883–5175); trigger `MeshhessenClient/TelemetryWindow.xaml.cs` (~315–332); manual position picker `MeshhessenClient/MapPickWindow.xaml.cs`.
- Data sources on the Mac after the prerequisite plans: `rf_links` / `rf_link_obs` (plan 022), `packet_rx` (own hop-0 receptions with RSSI/SNR), `node_positions` (plan 004), LocalStats noise floor in `local_stats_telemetry`, node positions in `AppState`.
- Map drawing: lines via `setLines(key, fc)` in `MeshHessen/Resources/VectorMap/map.html` and the traceroute overlay path in `MeshHessen/Views/MapView.swift` / `VectorMeshMapView.swift` — read how traceroute layers are added/removed (legend entry with ✕) and reuse that mechanism.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Facts to port (summary — C# is the truth; constants must match exactly)

- **Distance model**: `d_km = clamp(10^((P1 − RSSI) / (10·n)), 0.3, 60)`; defaults P1 = −90 dBm (RSSI at 1 km), n = 2.5, σ = 6 dB. SNR-only observations are converted to pseudo-RSSI = SNR + the observer's noise floor (−105 dBm when unknown); the own node uses its measured RSSI. Signal value per link = 5 %-trimmed median over 30 days.
- **Self-calibration** (`FitCalibration`): samples = links whose both ends have positions (position error ≤ 0.5 km), distance 0.2–80 km; needs ≥ 8 samples and max/min distance ratio ≥ 3; ordinary least squares of RSSI on log10(d); slope must be negative; clamp n to [1.8, 4.5], P1 to [−110, −70], σ = RMSE clamped to [3, 12]; report R² and whether clamping occurred. The user chooses between the fitted and the default model; recommend the fitted one only if R² ≥ 0.2 and nothing was clamped.
- **Anchor uncertainty**: distance factor `max(10^(σ/(10n)), 1.5)`; σ_km = `(factor − 1) · d · mul`, mul = 1.0 (RSSI), 1.3 (two-sided SNR), 1.7 (one-sided SNR), +0.3 when the default noise floor was used. Position error from precision bits: `2^(32 − bits) · 1e-7 · 111.32 / 2` km (acts as a dead zone).
- **Prior**: if the target reports a (coarse) position, add it as an anchor with d = 0, weight 5, error `max(err, 0.2)` km (0.05 when marked exact).
- **Solver** (`Estimate`): Huber loss (K = 1.5) on `(|r − d| − E) / σ`; 81×81 grid scan, then normalised gradient descent (300 iterations, step 0.01); accepted region cost ≤ 1.6·best + 0.02; an alternative solution is reported when a cell farther than `max(3 km, 4·gridStep)` has cost ≤ 1.4·best + 0.02; uncertainty radius = 90th-percentile distance inside the main cluster. Minimum 2 anchors with position and signal.
- **Terrain term** (only when the terrain service exists): `PathExcessLossDb` (knife-edge loss of the real profile minus that of flat ground, 24 samples, capped at 25 dB) scales the distance by `10^(loss / (10n))`.
- **Expert corrections**: `AdjustedRssi = rssi − ((tx + txAnt + rxAnt) − (22 + 2·1))` with per-hardware TX power presets (table in the C#).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Triangulation` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: new `MeshHessen/Services/TriangulationService.swift` (pure), `MeshHessen/Services/TriangulationDataProvider.swift` (DB queries → anchors), `MeshHessen/Views/TriangulationSheet.swift`; `MeshHessen/Services/TelemetryDatabaseService.swift` (read queries only), `MeshHessen/Views/TelemetryView.swift` (hidden trigger), `MeshHessen/Views/MapView.swift`, `MeshHessen/Views/VectorMeshMapView.swift`, `MeshHessen/Resources/VectorMap/map.html` (ring/region layer functions), `MeshHessen/Localizable.xcstrings`; `Tests/MeshHessenTests/TriangulationTests.swift`.

**Out of scope**: the manual map-pick window and per-node "position exact" expert flags (leave hooks: the provider accepts an optional override dictionary); writing estimated positions into the node database (estimates are display-only).

## Git workflow

Branch `feat/029-triangulation`. Commit per step. Do not push.

## Steps

### Step 1: Port the pure service and all tests
`TriangulationService.swift` as an `enum` of static functions with plain value types (no Core Location dependency in the math; use lat/lon doubles and a local equirectangular projection exactly as the C# does). Port every test in `TriangulationTests.cs`.

**Verify**: `swift test --filter Triangulation` → all pass.

### Step 2: Data provider
Queries: trimmed-median signal per (observer, neighbour) over 30 days from `rf_link_obs` and from `packet_rx` (hop 0, non-MQTT) for the own node; latest noise floor per node; positions (live `AppState`, else `node_positions`); calibration samples (links with both positions). Output: `[TriangulationAnchor]` for a target node + optional fitted calibration.

### Step 3: UI
- Hidden trigger: triple-click on the analysis footer line in `TelemetryView.swift` reveals a "Triangulate position" button (per window lifetime).
- `TriangulationSheet`: target node picker (nodes with ≥ 2 usable anchors), model choice (default vs. self-calibrated with both parameter sets and R² shown; pre-selected per the recommendation rule), result text (estimated coordinates, uncertainty radius, number of anchors, alternative solution if any) with the disclaimer "Rough estimate — terrain dominates LoRa links.", and "Show on map".

### Step 4: Map layers
Vector: JS `setTriangulation(geojson)` / `clearTriangulation()` — dashed circle polygons around anchors with a distance label, a translucent filled polygon for the uncertainty region, a triangle marker for the estimate (and the alternative). Raster: `MKCircle` overlays (dashed renderer), an `MKPolygon` region, an annotation. Register the layer in the same legend/removal mechanism traceroutes use. If `TerrainService` exists, apply the terrain term in the provider; if not, skip it (log once).

**Verify**: `swift build` exit 0 after each step; `swift test` → all pass; app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 including the ported `Triangulation` suite; xcodebuild Debug build succeeds
- [ ] The feature is unreachable without the triple-click trigger
- [ ] Estimated positions are never written to `AppState.nodes`, Core Data or `node_positions`
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `rf_link_obs` or `node_positions` do not exist (prerequisite plans not done).
- A ported solver test fails after two attempts — report the test name and both numbers; do not loosen tolerances.
- The legend/removal mechanism for map layers cannot host a non-traceroute layer without changing its data model.

## Maintenance notes

- This feature can suggest where a GPS-less node is. It only uses data the mesh already broadcasts, but the UI must keep the "rough estimate" framing and must never present the result as a node's reported position.
- Self-calibration is biased early on (only working links are recorded) — keep the model-choice dialog.
