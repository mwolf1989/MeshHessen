# Plan 019: Dashboard widgets have warn and alarm zones with zone colouring and transition notifications

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Models/TelemetryDashboardModels.swift MeshHessen/Services/TelemetryDashboardStore.swift MeshHessen/Views/TelemetryDashboardView.swift MeshHessen/Views/TelemetryDashboardWidgetViews.swift`
> Plan 005 is expected to have changed chart-scale modifiers and the gauge tint in `TelemetryDashboardWidgetViews.swift`.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW–MED (persisted widget model migration)
- **Depends on**: plans/005-telemetry-data-correctness.md
- **Category**: direction (feature parity with Windows 1.7.0, "Grafana round")
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Windows replaced the single threshold per widget with four bounds — warn low/high and alarm low/high — colours gauge/stat values by zone, draws the bounds into charts, and notifies on every zone change including recovery. The Mac has only alarm min/max (strict comparison, notification only when entering an alarm) plus a legacy `threshold` line. Storm-distance style metrics ("alarm when *below* 10 km") and early warnings are not expressible.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI + Swift Charts; tests in `Tests/MeshHessenTests/` (Swift Testing; `TelemetryDashboardParityTests.swift` covers the dashboard model and is the pattern).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Models/DashboardModels.cs` (~14–60), `MeshhessenClient.Tests/DashboardAlarmTests.cs`, `MeshhessenClient/TelemetryDashboardWindow.xaml.cs`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

`MeshHessen/Models/TelemetryDashboardModels.swift` (~164):
```swift
enum TelemetryAlarmState: String, Codable, Hashable, Sendable { case normal, belowMinimum, aboveMaximum }

enum TelemetryAlarmEvaluator {
    static func state(value: Double, minimum: Double?, maximum: Double?) -> TelemetryAlarmState {
        guard value.isFinite else { return .normal }
        if let minimum, minimum.isFinite, value < minimum { return .belowMinimum }
        if let maximum, maximum.isFinite, value > maximum { return .aboveMaximum }
        return .normal
    }
    static func shouldNotify(previous: TelemetryAlarmState, current: TelemetryAlarmState) -> Bool {
        previous == .normal && current != .normal
    }
}

struct TelemetryDashboardWidget: Identifiable, Codable, Hashable, Sendable {
    ...
    var threshold: Double?
    var displayMinimum: Double?
    var displayMaximum: Double?
    var alarmMinimum: Double?
    var alarmMaximum: Double?
    var showMovingAverage: Bool
```
The widget is `Codable` and persisted by `TelemetryDashboardStore` (`MeshHessen/Services/TelemetryDashboardStore.swift`); the alarm service that posts notifications is in the same file (~270–360). The widget editor is in `MeshHessen/Views/TelemetryDashboardView.swift`; chart/gauge/stat views in `MeshHessen/Views/TelemetryDashboardWidgetViews.swift` (single `threshold` RuleMark ~283, gauge ~405–430, stat ~446–480).

Windows rules: classification is **inclusive** — alarm-low if `value <= alarmLow`, alarm-high if `value >= alarmHigh`, then warn-low / warn-high the same way, else OK (alarm wins over warn). A legacy single threshold becomes alarm-high when no zones are set. A notification is sent on **every** zone change: entering alarm (🚨), entering warn (⚠), returning to OK (✅ all clear).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter TelemetryDashboard` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the four files in the drift check, `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/TelemetryDashboardParityTests.swift` (extend).

**Out of scope**: chart zoom, PNG export, full-screen, widget duplication, CSV variants (candidates for a later plan); the µSv/h conversion (plan 013).

## Git workflow

Branch `feat/019-dashboard-zones`. Conventional commits per step. Do not push.

## Steps

### Step 1: Model
- Add `var warnMinimum: Double?`, `var warnMaximum: Double?` to `TelemetryDashboardWidget`. Decode with `decodeIfPresent` so existing saved dashboards load (if the struct uses synthesized `Codable`, write an explicit `init(from:)` that tolerates missing keys for **all** optional/newer fields — check how `alarmMinimum` was added before and follow that).
- Migration on decode: if `threshold != nil` and all four zone bounds are nil → `alarmMaximum = threshold`, `threshold = nil`.
- New `enum TelemetryZone: String, Codable { case ok, warnLow, warnHigh, alarmLow, alarmHigh }` with `var severity: Int` (0 ok, 1 warn, 2 alarm), and `TelemetryAlarmEvaluator.zone(value:warnMinimum:warnMaximum:alarmMinimum:alarmMaximum:)` (inclusive). Keep the old `state(...)`/`TelemetryAlarmState` only if other code still needs them; otherwise replace usages.
- `static func shouldNotify(previous: TelemetryZone, current: TelemetryZone) -> Bool { previous != current }`.

**Verify**: `swift build` exit 0.

### Step 2: Notifications
In the alarm service, track the last zone per widget (it already tracks the last alarm state) and on change post: alarm → "🚨 <widget title>: <value> <unit>", warn → "⚠ …", ok → "✅ <widget title>: back to normal". The first evaluation after app start with zone `ok` must not notify.

### Step 3: Editor
Replace the alarm min/max fields by four optional number fields in a grid: "Warn low", "Warn high", "Alarm low", "Alarm high" (empty = off). Remove the separate threshold field from the editor.

### Step 4: Rendering
- Gauge and Stat: value colour by zone — ok green, warn orange, alarm red; with no bounds configured use the neutral colour. Gauge: draw an outer ring (a second `Circle().trim` arc set, or a `Canvas`) marking warn (orange) and alarm (red) ranges on the gauge scale.
- Line / area / scatter / candlestick charts: `RuleMark(y:)` in orange for warn bounds and red for alarm bounds, plus a translucent red `RectangleMark` band beyond each alarm bound (to the visible domain edge).
- Bar / histogram charts where the metric is on the X axis: vertical `RuleMark(x:)` lines.
- Remove the old single-threshold RuleMark.

**Verify**: app build succeeds.

## Test plan

Extend `TelemetryDashboardParityTests.swift` (port the cases of Windows `DashboardAlarmTests.cs`):
- Inclusive bounds: value == alarmHigh → `.alarmHigh`; value == warnLow → `.warnLow`.
- Alarm wins over warn when both match.
- NaN/infinite value → `.ok`; nil bounds are ignored.
- Legacy JSON containing only `threshold: 80` decodes to `alarmMaximum == 80`, `threshold == nil`; JSON without the new keys decodes.
- `shouldNotify`: ok→warnHigh true, warnHigh→alarmHigh true, alarmHigh→ok true, ok→ok false.
- Existing tests that assert strict `<`/`>` or `previous == .normal` semantics must be updated — list them in your report.

**Verify**: `swift test --filter TelemetryDashboard` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] `grep -n "warnMinimum" MeshHessen/Models/TelemetryDashboardModels.swift` ≥ 1 match
- [ ] A dashboard file saved by the previous app version still loads (covered by the legacy-JSON test)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The persisted dashboard format is not plain `Codable` JSON of these structs.
- Changing notification semantics breaks more than five existing tests.

## Maintenance notes

- Zone bounds are stored in the metric's storage unit; plan 013's µSv/h option converts at display time — if both land, the editor must show/accept bounds in the displayed unit.
- Reviewer: check an old dashboard with thresholds after upgrade, and that recovery ("back to normal") notifies exactly once.
