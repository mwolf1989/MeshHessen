# Plan 027: Environment sensor data is shown on the map as value boxes and an interpolated heatmap

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Views/MapView.swift MeshHessen/Views/VectorMeshMapView.swift MeshHessen/Resources/VectorMap/map.html MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Services/SettingsService.swift`

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: MED (two map renderers)
- **Depends on**: none hard; plans/013 adds metrics that should appear in the selector if present
- **Category**: direction (feature parity with Windows 1.6.3 / 1.6.4.6)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Nodes with weather sensors report temperature, humidity, pressure, wind, radiation and more. Windows shows these on the map: a small value box next to each sensor node and an interpolated colour surface (heatmap with legend and contour bands) for a selected metric, plus virtual metrics SNR / RSSI / noise floor. The Mac stores all this data but shows none of it on the map.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI. Two map renderers: MapKit raster (`MeshHessen/Views/MapView.swift`, overlays/annotations) and MapLibre GL in a `WKWebView` (`MeshHessen/Views/VectorMeshMapView.swift` + `MeshHessen/Resources/VectorMap/map.html`). Swift calls JS functions such as `setNodes(nodes)`, `setLines(key, fc)`, `removeLines(key)` (defined in `map.html` ~217–260); JS posts events back via `post(type, data)` (~114).
- Reference (READ-ONLY, **authoritative** — port the math and its tests): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/EnvironmentField.cs`, `EnvironmentHeatmapBuilder.cs`, `EnvironmentMetricInfo.cs`, `EnvironmentContours.cs`, `EnvironmentZones.cs`, `EnvironmentRaster.cs`, `MeshhessenClient/MainWindow.Environment.cs`, `MeshhessenClient.Tests/EnvironmentTests.cs`, JS in `MeshhessenClient/Resources/VectorMap/map.html` (~275–460: `setEnvBoxes`, `setEnvSurface`, `updateEnvLegend`).
- Stored data: table `environment_telemetry` in `MeshHessen/Services/TelemetryDatabaseService.swift` (~180–207), sample struct `EnvironmentTelemetrySample` in `MeshHessen/Models/TelemetryPersistenceModels.swift` (~320).
- Settings pattern: `MeshHessen/Services/SettingsService.swift` computed properties with `access(keyPath:)`/`withMutation(keyPath:)`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Facts to port (summary — C# is the truth)

- **Representative value per node** (`EnvironmentHeatmapBuilder`): from the node's recent samples, weighted by recency (value half-life 12 h); a confidence that decays with age (half-life 24 h).
- **Field** (`EnvironmentField`): inverse-distance weighting on a grid over the bounding box of sensor nodes (+ influence radius 30 km): weight = `confidence / (d² + 1 km²)`; cell size = `max(influence / 6, 0.5 km)`; 8–80 cells per axis, at most 2800 cells; cell alpha = `1 − nearestSensorDistance / influence` (cells beyond the influence radius are transparent).
- **Metric table** (`EnvironmentMetricInfo` ~31–102): key, DB column, unit, decimals, min, max, step (e.g. temperature −10…40 in 5 °C steps), colour gradient and banded legend; virtual metrics snr (−20…12, step 4), rssi (−130…−60), noise_floor (−130…−80).
- **Contours / zones**: band boundaries at the metric's steps, outer border, per-zone averages.
- **Settings**: show environment data (bool), box mode off / always / hover, show heatmap (bool), selected metric, list of excluded node ids.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Environment` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: new `MeshHessen/Services/Environment/EnvironmentMetricInfo.swift`, `EnvironmentHeatmapBuilder.swift`, `EnvironmentField.swift`, `EnvironmentContours.swift`, `EnvironmentRaster.swift`; the five files in the drift check; `MeshHessen/Views/EnvironmentMapControls.swift` (create); `MeshHessen/Localizable.xcstrings`; `Tests/MeshHessenTests/EnvironmentTests.swift` (create).

**Out of scope**: 3D terrain (plan 028), new sensor types (plan 013), dashboard.

## Git workflow

Branch `feat/027-environment-overlay`. Commit per step. Do not push.

## Steps

### Step 1: Pure math + tests
Port the five C# services (value types, no UI types; colours as `(r, g, b, a)` UInt8 tuples) and `EnvironmentTests.cs`.

**Verify**: `swift test --filter Environment` → pass.

### Step 2: Data query
`TelemetryDatabaseService.latestEnvironmentPerNode(metricColumn:maxAgeHours:) async -> [EnvironmentNodeSamples]` (recent samples per node for the builder; mirror Windows `GetLatestEnvironmentPerNode` ~1196). Column names must come from the metric table, never from user input.

### Step 3: Settings + controls
Add the five settings. `EnvironmentMapControls`: a compact map toolbar popover — master toggle, metric picker (only metrics that currently have data), box mode, heatmap toggle, node exclusion list, legend (banded colour scale with unit).

### Step 4: Vector map
Add JS functions to `map.html` modelled on the Windows versions: `setEnvBoxes(items)` (HTML markers with value + unit; hover mode shows them on node hover), `setEnvSurface(geojsonOrImage, bounds)` (a GeoJSON fill layer of grid cells with per-feature colour/opacity, inserted below symbol layers), `clearEnv()`, and re-add them after style reloads (see how `restoreLineLayers` ~349 does it for lines). Call them from `VectorMeshMapView` when settings/data change (debounced; recompute off the main actor).

### Step 5: Raster map
In `MapView.swift`: value boxes as annotations; the surface as one `MKOverlay` image (render the grid to a `CGImage` with bilinear smoothing via `EnvironmentRaster`, alpha per cell) drawn by an `MKOverlayRenderer` below annotations.

### Step 6: Refresh
Recompute when new environment telemetry arrives for the selected metric (throttle to at most once per 30 s) and when the selection changes.

**Verify**: `swift build` exit 0 after each step; app build succeeds after steps 4–6; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 including the ported `Environment` suite; xcodebuild Debug build succeeds
- [ ] With the master toggle off, no environment code runs per map update (guard at the top of the refresh function)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The ported field tests fail after two attempts — report expected vs. actual numbers.
- Adding JS layers breaks existing map functions (nodes/lines/emergency layers) — the existing `map.html` function names must keep working unchanged.
- The raster overlay cannot be drawn below annotations with the existing overlay stack.

## Maintenance notes

- The heatmap is an interpolation between sparse sensors — keep the legend and the influence-radius fade so it is not read as measured coverage.
- Reviewer: check both renderers, dark and light map styles, zooming performance with ~50 sensor nodes, and that toggling off removes every layer.
