# Plan 013: Lightning and soil/water telemetry are stored and charted; radiation can be shown in µSv/h

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Models/TelemetryPersistenceModels.swift MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/SettingsService.swift MeshHessen/Views/SettingsView.swift`

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW–MED (SQLite schema migration)
- **Depends on**: plans/002-protobuf-v2.8.2-and-firmware-capabilities.md (hard)
- **Category**: direction (feature parity with Windows 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Firmware 2.8 adds a lightning sensor (AS3935: strikes per hour, storm distance) to the environment metrics and a whole new telemetry variant for soil/water probes (pH, conductivity, salinity, NPK, dissolved oxygen, ORP, turbidity, nitrate, ammonium, solar irradiance …). Windows 1.7.2 stores and charts them and lets users display radiation in µSv/h instead of µR/h. The Mac drops these values.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing). `Tests/MeshHessenTests/TelemetryDashboardParityTests.swift` and `PersistenceTests.swift` show how telemetry DB tests are written.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/EnvironmentMetricInfo.cs` (metric table ~31–102, µSv conversion ~142–152, lightning ~186, soil/water ~194–215), `MeshhessenClient/Services/MeshtasticProtocolService.cs` (~2999–3006), `MeshhessenClient/TelemetryDashboardWindow.xaml.cs` (ranges ~2551–2555).
- Confirm generated Swift names by grep in `MeshHessen/Generated/telemetry.pb.swift` (expected: `lightningStrikeCount1H`/`hasLightningStrikeCount1H`, `lightningDistanceKm`, oneof case `.soilWaterMetrics`).
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `MeshHessen/Models/TelemetryPersistenceModels.swift`: `enum TelemetrySeriesMetric: String, CaseIterable …` — raw values are stable storage keys (e.g. `case radiation`, `case soilMoisture = "soil_moisture"`); further down each metric has unit/title/suggested range metadata (radiation unit is hard-coded "µR/h", ~254) and there is a primary list `windowsDashboardMetrics` (~291); `EnvironmentTelemetrySample` (~320) is the stored struct.
- `MeshHessen/Services/TelemetryDatabaseService.swift`: table `environment_telemetry` (~180–207) with one column per sensor; an "add missing column" migration map (~319–329); insert (~681–698); generic `telemetry_samples` written through `insertSamples(nodeId:timestamp:variant:values:isDay:on:)`.
- `MeshHessen/Services/MeshtasticProtocolService.swift` `handleTelemetry`: `switch telemetry.variant` with cases `.deviceMetrics` (~2664), `.environmentMetrics` (~2692), `.airQualityMetrics`, `.powerMetrics`, `.localStats`, `.healthMetrics`, `.hostMetrics`, `.trafficManagementStats`. Read the `.environmentMetrics` case fully — it is the pattern for extracting optional fields into a sample and a `[TelemetrySeriesMetric: Double]` dictionary.
- Settings pattern (`MeshHessen/Services/SettingsService.swift`, e.g. `locationLoggingEnabled` ~659): computed property with `access(keyPath:)` / `withMutation(keyPath:)` over `defaults`.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter NewSensorTelemetry` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the five files in the drift check, `MeshHessen/Views/TelemetryDashboardWidgetViews.swift` and `MeshHessen/Services/TelemetryDashboardStore.swift` (unit conversion only), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/NewSensorTelemetryTests.swift` (create).

**Out of scope**: map overlays (plan 027), alarm-zone model (plan 019), changing stored units (radiation stays µR/h in the DB).

## Git workflow

Branch `feat/013-new-sensor-telemetry`. Conventional commits. Do not push.

## Steps

### Step 1: Metrics
Add `TelemetrySeriesMetric` cases (raw values = snake_case storage keys): `lightningStrikeCount1Hour = "lightning_strike_count_1h"` (range 0–30, unit "/h"), `lightningDistance = "lightning_distance_km"` (0–40, "km"), `soilPH = "soil_ph"` (0–14), `waterPH = "water_ph"` (0–14), `electricalConductivity = "electrical_conductivity"`, `salinity`, `nitrogen`, `phosphorus`, `potassium`, `dissolvedOxygen = "dissolved_oxygen"`, `orp`, `chemicalOxygenDemand = "chemical_oxygen_demand"`, `biochemicalOxygenDemand = "biochemical_oxygen_demand"`, `turbidity`, `nitrate`, `ammonium`, `solarIrradiance = "solar_irradiance"`. Fill in every per-metric switch in the file (title, unit, range, variant) — take units/ranges from Windows `EnvironmentMetricInfo.cs`; where Windows has none use an empty unit and no suggested range. Add lightning (both), `soilPH` and the existing `radiation` to the primary dashboard list.

**Verify**: `swift build` exit 0 (compiler finds missed switches).

### Step 2: Storage
- Lightning: add two nullable columns to `environment_telemetry` and to the migration map; add the fields to `EnvironmentTelemetrySample` and the insert/select code.
- Soil/water: create table `soil_water_telemetry` (id, node_id, timestamp, is_day, one nullable REAL column per field above) following the structure of `environment_telemetry`; add it to `telemetryTableNames`; add `insertSoilWaterTelemetry(...)`. Also write each present value into `telemetry_samples` via `insertSamples(… variant: "soil_water" …)` so the generic dashboard query works without further changes.

### Step 3: Extraction
- In the `.environmentMetrics` case: strike count is kept even when 0 (if the field is present); distance 0 is dropped.
- Add `case .soilWaterMetrics(let m):` — every field is proto3-optional: include a value only when its `has…` accessor is true.
- If a second switch over `telemetry.variant` exists (~3054, used for request classification), add the new case there, classified like environment.

### Step 4: µSv/h display option
- `SettingsService`: `var radiationInSievert: Bool` (key `"radiationInSievert"`, default false) using the existing property pattern; a toggle "Show radiation in µSv/h" in `SettingsView.swift` near the other telemetry settings.
- Add `enum RadiationUnit { static let microRoentgenPerMicroSievert = 100.0; static func display(_ microRoentgen: Double, inSievert: Bool) -> Double }` in `TelemetryPersistenceModels.swift`.
- Apply at display time for metric `.radiation` only: the unit string, series values handed to charts/stat/gauge, the suggested range, and alarm/threshold bounds entered by the user (bounds are entered and shown in the displayed unit, compared in the displayed unit). Find the single place where widget series are produced (`TelemetryDashboardStore` / data loader) and convert there rather than in each chart.

**Verify**: app build succeeds.

## Test plan

`NewSensorTelemetryTests.swift`:
- Every new metric has a unique raw value and non-empty title (`TelemetrySeriesMetric.allCases` raw values are unique).
- DB round trip: insert an environment sample with lightning values → read back; insert soil/water sample → `telemetry_samples` contains `soil_ph`.
- Opening a database created with the **old** schema (create the old `environment_telemetry` table manually in a temp DB, then open the service) adds the two columns without data loss.
- `RadiationUnit.display(250, inSievert: true) == 2.5`; `inSievert: false` → 250.

**Verify**: `swift test --filter NewSensorTelemetry` → pass; `swift test` → all pass.

## Done criteria

- [ ] `grep -n "soilWaterMetrics" MeshHessen/Services/MeshtasticProtocolService.swift` ≥ 1 match
- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The generated telemetry code has no soil/water variant or lightning fields.
- The column-migration mechanism is not a simple "add missing columns" map.
- Unit conversion would require touching more than three chart view types individually.

## Maintenance notes

- New metric raw values are persisted keys — never rename them.
- Plan 027 (environment map overlay) should include these metrics in its selector.
