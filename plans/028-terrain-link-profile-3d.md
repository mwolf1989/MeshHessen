# Plan 028: Terrain elevation is available to the client — link elevation profiles and 3D terrain on the vector map

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/VectorTileCacheService.swift MeshHessen/Resources/VectorMap/map.html MeshHessen/Views/VectorMeshMapView.swift MeshHessen/Views/TracerouteSheet.swift MeshHessen/Views/TelemetryView.swift`

## Status

- **Priority**: P3
- **Effort**: L
- **Risk**: LOW–MED
- **Depends on**: none hard (plan 022 provides richer neighbour lists to open profiles from)
- **Category**: direction (feature parity with Windows 1.7.0)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

LoRa links are dominated by terrain. Windows 1.7.0 added a DEM (digital elevation model) service fed by the Mesh Hessen tile server, a link elevation profile window (terrain, earth bulge, line of sight, 60 % Fresnel zone and a verdict), and 3D terrain with hillshading plus a north arrow on the vector map. Plan 029 (triangulation) also uses the terrain service.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; vector map = MapLibre GL JS in a `WKWebView` (`MeshHessen/Views/VectorMeshMapView.swift`, `MeshHessen/Resources/VectorMap/map.html`; `initMap(...)` ~134 creates the map with `showCompass: false` ~152); tile/resource caching through `MeshHessen/Services/VectorTileCacheService.swift` (read its API — resources are fetched with the correct client identification and cached for offline use; **do not bypass this cache**).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/TerrainService.cs` (~11–192), `MeshhessenClient.Tests/TerrainGridTests.cs`, `MeshhessenClient/LinkProfileWindow.xaml.cs` (~10–158), `MeshhessenClient/Services/TriangulationService.cs` (`KnifeEdgeLossDb`, `PathFresnelV`, `PathExcessLossDb`), `MeshhessenClient/Resources/VectorMap/map.html` (~667–700 `setTerrainMode`).
- The terrain tile host is the same host the Mac already uses for Mesh Hessen vector resources — take the base URL from the existing Mesh Hessen map source definition (grep `meshHessenVectorStyleURL` in `MeshHessen/Models/`), and the path pattern `/terrain/{z}/{x}/{y}` from `TerrainService.cs`. Do not hard-code a host that is not already in the Mac code.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Facts to port (summary — C# is the truth)

- **Tiles**: Mapbox terrain-RGB, `height = -10000 + (R*65536 + G*256 + B) * 0.1` metres; zoom 10 preferred, falling back to coarser zoom down to 5 so that a bounding box needs at most 80 tiles; HTTP 204 = outside coverage (cells stay NaN).
- **Lookup**: bilinear interpolation in Web-Mercator pixel space; if some of the four corners are NaN use the nearest valid one.
- **Profile**: N samples along the great circle between two points (Windows uses 24 for loss estimation; use ~200 for drawing); earth bulge with 4/3 effective earth radius; line of sight between antenna heights (default 2.5 m above ground each end); first Fresnel radius `f1 = sqrt(λ * d1 * d2 / d)` with `λ = 299.79 / 868` m; clearance margin = LOS − 0.6·f1 − (ground + bulge); verdict from the worst margin and the knife-edge diffraction loss (ITU-R P.526 approximation as implemented in `KnifeEdgeLossDb`).
- **3D terrain (JS)**: `map.addSource('terrain-dem', { type: 'raster-dem', tiles: [url], tileSize: 256 })`, `map.setTerrain({ source: 'terrain-dem', exaggeration: 1.3 })`, a `hillshade` layer (exaggeration 0.35) inserted below the first symbol layer; removing all three when switched off; a north arrow control that appears when bearing or pitch ≠ 0 and resets on click.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter Terrain` / `--filter LinkProfile` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: new `MeshHessen/Services/TerrainService.swift`, `MeshHessen/Models/LinkProfile.swift`, `MeshHessen/Views/LinkProfileSheet.swift`; the five files in the drift check; `MeshHessen/Services/SettingsService.swift` (one setting: 3D terrain on/off); `MeshHessen/Localizable.xcstrings`; tests `Tests/MeshHessenTests/TerrainGridTests.swift`, `LinkProfileTests.swift`.

**Out of scope**: triangulation (plan 029); raster (MapKit) 3D; offline pre-download of terrain packages (the existing offline package manager may already include height data — do not change it).

## Git workflow

Branch `feat/028-terrain`. Commit per step. Do not push.

## Steps

### Step 1: Terrain grid (pure) + tests
`struct TerrainGrid` (decoded heights for a tile set, bilinear lookup `height(latitude:longitude:) -> Double?`) and tile math (lat/lon ↔ tile x/y/pixel). Port `TerrainGridTests.cs`. Decoding: `CGImage` → RGBA8 bitmap (`CGContext`, premultiplied-last; terrain tiles are opaque).

### Step 2: `TerrainService`
`actor TerrainService`: `func grid(covering bounds:) async -> TerrainGrid?` — picks the zoom (≤ 80 tiles), loads tiles through the existing cache service, decodes, memoises recent grids. Returns nil when no tile could be loaded (offline without cache).

### Step 3: Link profile model (pure) + tests
`LinkProfile.compute(from:to:antennaHeights:grid:samples:) -> LinkProfileResult` (distances, ground heights, bulge, LOS line, Fresnel radii, worst margin, knife-edge loss, verdict enum: clear / marginal / obstructed / unknown). Port the knife-edge and Fresnel helpers from `TriangulationService.cs` together with the tests that cover them in `TriangulationTests.cs`. Tests: flat terrain 10 km → clear, margin ≈ `2.5 − bulge − 0.6·f1` at mid-path; a single 300 m ridge mid-path → obstructed with loss > 6 dB; unknown heights → verdict unknown.

### Step 4: Profile sheet
`LinkProfileSheet` (Swift Charts): area for terrain + bulge, line for LOS, band for the 60 % Fresnel zone, header with distance, worst clearance, estimated extra loss and verdict; antenna-height fields (default 2.5 m). Open it from: a traceroute hop's context menu in `TracerouteSheet.swift` (between consecutive hops with positions) and a neighbour row's context menu in `TelemetryView.swift` (own node ↔ neighbour). Disabled with a tooltip when either end has no position.

### Step 5: 3D terrain on the vector map
`map.html`: `setTerrainMode(on, url, exaggeration)` and the north arrow per the facts above; terrain tile requests must go through the same `proxyUrl(url, resourceType)` mechanism (~125) other resources use so they hit the cache. `VectorMeshMapView`: a toolbar toggle bound to the new setting; re-apply after style changes.

**Verify**: `swift build` exit 0 after each step; `swift test` → all pass; app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 with `Terrain` and `LinkProfile` suites; xcodebuild Debug build succeeds
- [ ] Terrain tiles are requested only through the existing cache/proxy path (no direct `URLSession` to the tile host in `TerrainService.swift`)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The existing cache service cannot fetch arbitrary binary resources (PNG terrain tiles) — report its API rather than bypassing it.
- The terrain endpoint's host or path cannot be determined from the Mac code plus `TerrainService.cs` with confidence.
- `raster-dem` tiles fail to load through the `WKWebView` resource scheme handler (`MeshHessen/Services/VectorResourceSchemeHandler.swift`) without changing that handler's request filtering.

## Maintenance notes

- Coverage is limited to the tile server's region (Germany/Austria/Switzerland); outside it the profile shows "no elevation data".
- Reviewer: compare one profile against the Windows client for the same two nodes; check 3D toggle, rotate/tilt, north arrow, and that the environment heatmap (plan 027), if present, still renders when 3D is on (Windows suspends draping while the heatmap is visible).
