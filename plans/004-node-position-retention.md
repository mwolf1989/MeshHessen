# Plan 004: Known node positions survive NodeInfo broadcasts, restarts and device NodeDB eviction

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/AppState.swift MeshHessen/Persistence/MeshCoreDataStore.swift MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/TelemetryDatabaseService.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW–MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Users see node positions "disappear" from the map. Cause on the Mac: every NodeInfo broadcast received over radio (a `User` packet — it never contains a position) is turned into a fresh `NodeInfo` without coordinates and written to Core Data as-is, overwriting the stored latitude/longitude with nil. In memory the merge is fine, so the position vanishes only after the next app start. Additionally, positions that arrive *before* the node's NodeInfo are dropped, and nothing restores positions the radio itself has forgotten. Windows fixed all three (1.6.1.3 and 1.7.0).

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing: `import Testing`, `@testable import MeshHessen`). Baseline at planning time: `swift test` → 261 tests pass.
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/MeshtasticProtocolService.cs` (`MergeNodeInfo_NoLock`, `PendingPosition`, `ApplyPendingPosition_NoLock`), `MeshhessenClient/Services/TelemetryDatabaseService.cs` (`node_positions`, `GetLatestPositions`), `MeshhessenClient.Tests/NodePositionRetentionTests.cs`.
- Conventions: 4-space indent; `AppLogger.shared.log(...)`; never edit `MeshHessen/Generated/`. New files are auto-included in Xcode and SPM.

## Current state

`MeshHessen/Services/MeshtasticProtocolService.swift`:
- `handleNodeInfoPacket` (~1121) ends with
  ```swift
  let node = makeNodeInfo(from: user, num: nodeId)
  appState?.upsertNode(node)
  coreDataStore?.upsertNode(node)        // <- partial object, no position
  ```
- `handleNodeInfo` (~1148) ends with `appState?.upsertNode(node, refreshNodeDatabaseFlags: true)` / `coreDataStore?.upsertNode(node)` (same problem when the device snapshot has no position).
- `handlePosition` (~1092): updates `appState.node(forId:)` only `if let node = …`; otherwise the position is discarded. It does not persist the position anywhere except the optional `LocationLogger`.

`MeshHessen/AppState.swift` `upsertNode` (~355) merges in place (position only overwritten by non-nil values) but has three gaps: `existing.viaMqtt = info.viaMqtt` is unconditional; `lastHeard` can move backwards; hardware model / role / public key are never refreshed (check which of these properties exist on `NodeInfo` in `MeshHessen/Models/NodeInfo.swift`).

`MeshHessen/Persistence/MeshCoreDataStore.swift` `upsertNode` (~491) writes every attribute unconditionally, e.g.
```swift
object.setValue(node.latitude, forKey: "latitude")
object.setValue(node.longitude, forKey: "longitude")
object.setValue(node.altitude.map { Int64($0) }, forKey: "altitude")
```

`MeshHessen/Services/TelemetryDatabaseService.swift` is a hand-written SQLite wrapper (`enqueueWrite { service, db in … }`, `service.run(sql, bindings:, on:)`; schema creation block around lines 140–250; `telemetryTableNames` near line 57 drives retention cleanup). It has no position table.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter NodePositionRetention` | all pass |
| All tests | `swift test` | all pass (≥ 261) |

## Scope

**In scope**: `MeshHessen/AppState.swift`, `MeshHessen/Services/MeshtasticProtocolService.swift` (the three handlers + a pending-position buffer + backfill call), `MeshHessen/Services/TelemetryDatabaseService.swift` (new table + two functions), `Tests/MeshHessenTests/NodePositionRetentionTests.swift` (create).

**Out of scope**: Core Data model changes (no new model version); `LocationLogger`; map views; `MeshCoreDataStore.upsertNode` signature.

## Git workflow

Branch `fix/004-node-position-retention`. Conventional commits. Do not push.

## Steps

### Step 1: Persist the merged node, not the partial one
In both handlers, after `appState?.upsertNode(...)`, persist `appState?.node(forId: nodeId) ?? node` instead of `node`. (The merged in-memory object carries the retained position, battery, SNR.)

**Verify**: `swift build` exit 0; `grep -n "coreDataStore?.upsertNode(node)" MeshHessen/Services/MeshtasticProtocolService.swift` → no matches in `handleNodeInfoPacket`/`handleNodeInfo`.

### Step 2: Tighten the in-memory merge
In `AppState.upsertNode`:
- Add a parameter `fromDeviceDatabase: Bool` — or reuse `refreshNodeDatabaseFlags` — so `viaMqtt` is only taken from device NodeDB snapshots (same rule as `isFavorite`).
- `lastHeard`/`lastSeen` only move forward (`info.lastHeard > existing.lastHeard`).
- Treat latitude **and** longitude both `0` as "no position".
- Copy hardware model / role / public key when the incoming value is non-empty (only for properties that exist on `NodeInfo`).

### Step 3: Buffer positions of unknown nodes
In `MeshtasticProtocolService` add
```swift
private struct PendingPosition { let latitude: Double; let longitude: Double; let altitude: Int; let receivedAt: Date }
private var pendingPositions: [UInt32: PendingPosition] = [:]
```
`handlePosition`: when the node is unknown, store the entry (cap 500 entries — evict the oldest; entries older than 6 h are ignored). In `handleNodeInfoPacket` and `handleNodeInfo`, after the upsert, apply and remove a pending entry for that node (set lat/lon/alt on the merged node, call `recalculateDistance`). Clear the buffer on disconnect.

### Step 4: `node_positions` table
In `TelemetryDatabaseService` add to the schema block:
```sql
CREATE TABLE IF NOT EXISTS node_positions (
  id INTEGER PRIMARY KEY AUTOINCREMENT, node_id INTEGER NOT NULL,
  latitude REAL NOT NULL, longitude REAL NOT NULL, altitude INTEGER,
  ground_speed INTEGER, ground_track INTEGER, timestamp REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_node_positions_node_ts ON node_positions(node_id, timestamp DESC);
```
Add it to `telemetryTableNames` so retention covers it (check that the retention code deletes by a `timestamp` column; if it uses another column name per table, follow that mechanism). Add:
```swift
func insertNodePosition(nodeId: UInt32, latitude: Double, longitude: Double, altitude: Int?, groundSpeed: UInt32, groundTrack: UInt32, timestamp: Date)
func latestNodePositions(maxAgeDays: Int = 30) async -> [UInt32: (latitude: Double, longitude: Double, altitude: Int?)]
```
Query: latest row per node with `latitude != 0 AND longitude != 0 AND timestamp >= cutoff`. Follow the read pattern of an existing query function in the same file (e.g. `getDirectNeighborContacts`). To avoid flooding, skip the insert when the same node's last stored position is identical and younger than 10 minutes (keep a small in-memory dictionary).

Call `insertNodePosition` from `handlePosition` for every valid position (known or unknown node).

### Step 5: Backfill after connect
Where the init sequence finishes (`isInitializing = false`, comment `// 9. Finish init` in `MeshtasticProtocolService`), start a task: load `latestNodePositions()`, and for each node in `appState` **without** a position set lat/lon/alt from the DB and `recalculateDistance`. Never overwrite an existing position. Log the count with `AppLogger`.

**Verify**: `swift build` exit 0.

## Test plan

`NodePositionRetentionTests.swift` (use `Tests/MeshHessenTests/TestModelFactory.swift` and `ModelTests.swift` as patterns for building `NodeInfo`/`AppState`):
- Upsert a node with position, then upsert the same id from a position-less `NodeInfo` → position retained; `node(forId:)` still has coordinates.
- `viaMqtt` is not reset by a non-database upsert; `lastHeard` does not go backwards.
- 0/0 coordinates do not overwrite a real position.
- Telemetry DB (use the test initializer other DB tests use — grep `TelemetryDatabaseService(` in `Tests/`): insert two positions for a node, `latestNodePositions()` returns the newer; rows older than the cutoff are ignored; 0/0 rows are ignored.

**Verify**: `swift test --filter NodePositionRetention` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0 including the new suite
- [ ] `grep -n "node_positions" MeshHessen/Services/TelemetryDatabaseService.swift` shows table, insert and query
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `TelemetryDatabaseService` cannot be instantiated against a temporary file/in-memory DB in tests.
- `makeNodeInfo(from:num:)` turns out to populate latitude/longitude from some cache (then Step 1's premise is wrong — report what it does).
- The retention mechanism is not table-list driven.

## Maintenance notes

- Plan 029 (triangulation) and plan 022 (RF links) read `node_positions`.
- Reviewer: connect, wait for a NodeInfo broadcast of a node with a known position, restart the app — the node must still be on the map.
