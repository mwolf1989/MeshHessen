# Plan 012: Node status messages are shown, remembered and settable

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/TelemetryDatabaseService.swift MeshHessen/Models/NodeInfo.swift MeshHessen/Views/MainView.swift MeshHessen/Views/NodeInfoSheet.swift MeshHessen/Views/NodeListView.swift MeshHessen/Views/NodesTabView.swift`

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001 (for `UTF8Limits`); works with the current protobufs (port 36 and `StatusMessage` already exist)
- **Category**: direction (feature parity with Windows 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Since firmware 2.7.20 a node can broadcast a short free-text status ("Unterwegs", "Akku schwach") on port 36. Windows 1.7.2 shows other nodes' statuses in the node list and node info, remembers them across restarts (they are only re-broadcast about every 12 hours), and offers a one-click button to set your own. The Mac ignores port 36 completely; the own status can only be changed through the raw JSON editor.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/MeshtasticProtocolService.cs` (`HandleNodeStatusPacket` ~2066–2094, backfill ~546–560), `MeshhessenClient/Services/TelemetryDatabaseService.cs` (`node_status` ~173, `UpsertNodeStatus` ~274, `GetNodeStatuses` ~300), `MeshhessenClient/MainWindow.NodeStatus.cs`, `MeshhessenClient/NodeStatusDialog.cs`.
- Generated names to confirm by grep in `MeshHessen/Generated/`: portnum `.nodeStatusApp`, message `Meshtastic_StatusMessage` (field `status`), module config `statusmessage` with field `nodeStatus`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `handleMeshPacket` in `MeshHessen/Services/MeshtasticProtocolService.swift` (~650) switches on `data.portnum` with cases for text, position, nodeinfo, routing, admin, waypoint, telemetry, paxcounter, traceroute, neighborinfo; everything else is logged as unhandled. The PKI re-dispatch a few lines below has a similar switch.
- `MeshHessen/Models/NodeInfo.swift` has no status property.
- `MeshHessen/Services/TelemetryDatabaseService.swift` is a hand-written SQLite wrapper: writes via `enqueueWrite { service, db in service.run(sql, bindings: […], on: db) }`; schema block ~140–250; `telemetryTableNames` (~57) drives retention.
- Module configs are read/written through `requestCompleteConfiguration(from:selection:…)` / `saveCompleteConfiguration(_:replacing:to:…)` on `MeshtasticProtocolService` using `MeshConfigurationSnapshot` (`MeshHessen/Models/AdminConfigurationModels.swift`), which has a `statusMessage` module property. Saving a status change does not reboot the device.
- Toolbar/header: `MeshHessen/Views/MainView.swift` hosts `MeshStatusIndicatorsView` and toolbar buttons.

Status text limit: **79 UTF-8 bytes**. Empty text clears the status.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter NodeStatus` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: the seven files in the drift check, `MeshHessen/Views/NodeStatusSheet.swift` (create), `MeshHessen/AppState.swift` (only if needed to expose a helper), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/NodeStatusTests.swift` (create).

**Out of scope**: Core Data model changes; a native form for the whole StatusMessage module; kiosk masks.

## Git workflow

Branch `feat/012-node-status`. Conventional commits. Do not push.

## Steps

### Step 1: Receive
- `NodeInfo`: add `var status: String = ""`.
- Add `private func handleNodeStatusPacket(data:packet:)`: parse `Meshtastic_StatusMessage(serializedBytes: data.payload)`; trim; set `appState?.node(forId: packet.from)?.status`; persist (Step 2). Empty status clears. Ignore packets from unknown nodes except for persisting.
- Add `case .nodeStatusApp:` to both portnum switches.

### Step 2: Persist
In `TelemetryDatabaseService`:
```sql
CREATE TABLE IF NOT EXISTS node_status (node_id INTEGER PRIMARY KEY, status TEXT NOT NULL, timestamp REAL NOT NULL);
```
`func upsertNodeStatus(nodeId: UInt32, status: String, timestamp: Date)` (INSERT OR REPLACE; delete the row when status is empty) and `func nodeStatuses(maxAgeDays: Int = 7) async -> [UInt32: String]`. Do **not** add the table to `telemetryTableNames` unless the retention code handles a per-table timestamp column generically — a one-row-per-node table needs no retention.

### Step 3: Backfill after connect
Where init finishes (`isInitializing = false`, comment `// 9. Finish init`), load `nodeStatuses()` and set `status` on nodes whose status is empty.

### Step 4: Display
- Node rows in `NodeListView.swift` and `NodesTabView.swift` (table and grid): when `!node.status.isEmpty` show `Image(systemName: "text.bubble")` with `.help(node.status)`; in the grid tile show the text on its own line (`.lineLimit(1)`).
- `NodeInfoSheet.swift`: a banner row at the top with the status text when non-empty.

### Step 5: Set own status
- `MeshtasticProtocolService`: `func setOwnNodeStatus(_ text: String) async throws` — load the status-message module (`requestCompleteConfiguration` with a selection containing only `.statusMessage`; read `MeshConfigurationRequestSelection` to see how to build a narrow selection), copy the snapshot, set `statusMessage.nodeStatus = UTF8Limits.clamp(text, maxBytes: 79)`, and `saveCompleteConfiguration(updated, replacing: original, to: .local, …)`. Then update the own node's `status` locally and persist it.
- `NodeStatusSheet.swift`: text field, live "n/79 bytes" counter, Save / Clear / Cancel; errors shown via `@State private var errorMessage: String?` in an `.alert`.
- `MainView.swift`: a toolbar button (`text.bubble`) next to the status indicators, enabled only while connected, opening the sheet pre-filled with the own node's current status.

**Verify**: `swift build` exit 0; app build succeeds.

## Test plan

`NodeStatusTests.swift`:
- DB: upsert then read returns the status; upsert with empty string removes it; entries older than `maxAgeDays` are not returned (use the test DB initialiser other tests use — grep `TelemetryDatabaseService(` under `Tests/`).
- Parsing helper (make the payload→string step a `static func nodeStatusText(from payload: Data) -> String?`): a serialized `Meshtastic_StatusMessage` with `status = " Unterwegs "` → `"Unterwegs"`; garbage bytes → nil.
- `UTF8Limits.clamp("ä" * 50, 79)` yields 39 characters (78 bytes).

**Verify**: `swift test --filter NodeStatus` → pass; `swift test` → all pass.

## Done criteria

- [ ] `grep -n "nodeStatusApp" MeshHessen/Services/MeshtasticProtocolService.swift` ≥ 2 matches
- [ ] `swift test` exits 0; xcodebuild Debug build succeeds
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The generated code lacks `.nodeStatusApp` or `Meshtastic_StatusMessage`.
- A narrow (single-module) configuration request is not possible with the existing API and would require a new admin request path.
- `UTF8Limits` does not exist (plan 001 not done) — implement the clamp locally in this plan's sheet only if told to; otherwise stop.

## Maintenance notes

- Devices re-broadcast status roughly every 12 h, so the DB backfill is what makes statuses visible after a restart.
- Not verified on hardware. Reviewer: set a status, check a second client sees it; clear it.
