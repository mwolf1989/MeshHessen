# Plan 016: Undecryptable direct messages are kept and decrypted once the sender's key is known; unknown senders are resolved automatically

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Models/MessageItem.swift MeshHessen/AppState.swift MeshHessen/Views/SharedMessageViews.swift MeshHessen/Persistence`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED (Core Data model version, message flow)
- **Depends on**: plans/003-pki-aes-ccm-decryption.md (hard)
- **Category**: direction (feature parity with Windows 1.6.1.1 – 1.6.2.3)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

When a direct message arrives from a node whose public key the client does not know yet, it cannot be decrypted at that moment. Windows keeps the ciphertext, asks the sender for its NodeInfo (which contains the key), and replaces the "encrypted" bubble with the clear text as soon as the key arrives — also after a restart, and on demand through a 🔑 button. It also automatically requests NodeInfo for unknown senders (rate-limited) and renames earlier messages once the name is known. On the Mac such messages stay unreadable forever, and encrypted unicasts addressed to *other* nodes clutter the channel feed.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; Core Data model `MeshHessen/MeshHessen.xcdatamodeld` (compiled by Xcode only; excluded from SPM); tests in `Tests/MeshHessenTests/` (Swift Testing; `PersistenceTests.swift` / `MessagePersistenceParityTests.swift` show how persistence is tested).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/MeshtasticProtocolService.cs` — constants ~195–203, `BufferPendingPkiDm` ~1528, `RetryOrRequestPendingDm` ~1582, `DispatchLateDecrypted` ~1626, `RetryAllPendingWithKnownKeys` ~1673, `RequestNodeInfoAsync` ~1684–1740, `RequestUnknownNodeInfoThrottled` ~1743, `BuildOwnUser` ~1909, `HasRecentInfoRequest` ~2475, drop of foreign unicasts ~1495–1506; `MeshhessenClient/Models/MessageItem.cs` (`CanRetryDecrypt` ~84–96); `MeshhessenClient/Models/NodeInfo.cs` line 7 (`DefaultName`); `MeshhessenClient.Tests/PkiLateDecryptTests.cs`.
- UI strings: English in code + German in `MeshHessen/Localizable.xcstrings` (only add keys).

## Current state

- `.encrypted` branch of `handleMeshPacket` (`MeshHessen/Services/MeshtasticProtocolService.swift` ~668): PKI attempt, else `handleEncryptedPacket(packet)` (~805–845) which creates a placeholder `MessageItem`; encrypted unicasts to other nodes are delivered to the channel feed (~840).
- `requestNodeInfo` (~3000–3030) is manual only, always uses channel 0 and sends an empty user payload (`makeNodeInfoRequestData`, ~3041).
- `nodeDisplayName` (~3762) returns `"!%08x"` for unknown nodes.
- `AppState.upsertNode` (`MeshHessen/AppState.swift` ~355) does not touch existing messages.
- `MessageItem` (`MeshHessen/Models/MessageItem.swift`) has no ciphertext field; `MeshCoreDataStore.upsertMessage` (`MeshHessen/Persistence/MeshCoreDataStore.swift` ~639) persists messages; the Core Data model has no cipher attribute.
- Bubble UI: `MessageBubbleView` in `MeshHessen/Views/SharedMessageViews.swift` (~245).

Windows constants: per-node NodeInfo request interval 2 min; global gap between automatic requests 8 s; pending TTL 30 min; max 20 pending per node; an encrypted reply within 30 s of an explicit info request is buffered silently (not shown as chat).

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter LateDecrypt` | all pass |
| All tests | `swift test` | all pass |
| App build (compiles the Core Data model) | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Services/PendingPkiMessageBuffer.swift` (create), the files in the drift check (Core Data: add a **new model version** with one optional Binary attribute `cipher` on the message entity, lightweight migration), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/LateDecryptTests.swift` (create).

**Out of scope**: channel PSK decryption (plan 015); UI redesign of bubbles; changing `NodeKeyService` storage.

## Git workflow

Branch `feat/016-late-pki-decrypt`. Conventional commits per step. Do not push.

## Steps

### Step 1: Pure buffer + throttle
`PendingPkiMessageBuffer.swift`: a struct holding per-node arrays of `{ packetId, from, to, channel, blob, receivedAt, messageId }` with `mutating add(...)` (cap 20 per node, drop oldest), `mutating take(for node:, now:) -> [Entry]` (drops entries older than 30 min), and a `NodeInfoRequestThrottle` struct: `mutating func shouldRequest(node:, now:, force: Bool) -> Bool` implementing the 2-minute per-node and 8-second global rules (force bypasses both). Unit-test both (time injected).

### Step 2: Placeholder name
`nodeDisplayName` and the `NodeInfo.name` fallback for nodes without a user record: `"Meshtastic %04x"` of the low 16 bits (Windows `DefaultName`). Check tests that assert `"!%08x"` names and update them.

### Step 3: Buffer on failure, drop foreign unicasts
In the `.encrypted` branch:
- Unicast addressed to another node (`packet.to != myNodeId`, not broadcast): do not create a chat item; return.
- Addressed to us and PKI failed or the sender key is unknown: create the placeholder DM as today but set its `cipher` (Step 5) and add an entry to the buffer; then `requestNodeInfoIfAllowed(node: packet.from, channel: packet.channel)` (Step 4).
- If an explicit NodeInfo/position/telemetry request to that node was sent within the last 30 s (track a `[UInt32: Date]` in `requestNodeInfo`), buffer silently without a chat placeholder.

### Step 4: NodeInfo requests that actually deliver our key
- `requestNodeInfo`: payload = our own `Meshtastic_User` (long/short name, id, hardware model, and our public key if known — from the raw owner cache of plan 001 or `NodeKeyService`); channel = the given channel when ≤ 7, else the last channel index on which a packet was successfully decoded (track `lastGoodChannel` in `handleMeshPacket`), else 0.
- `requestNodeInfoIfAllowed` applies the throttle. Call it from `handleTextMessage` when the sender is unknown (`appState.node(forId:) == nil`).

### Step 5: Persist ciphertext
- `MessageItem`: `var cipher: Data?` and `var canRetryDecrypt: Bool { cipher != nil && isEncryptedPlaceholder }` (use the item's existing notion of "encrypted placeholder" — read the model).
- Core Data: add model version N+1 with optional Binary `cipher` on the message entity; set it as current; confirm the persistent container uses automatic lightweight migration (`PersistenceController.swift`). Write/read it in `MeshCoreDataStore` message upsert/hydration.

### Step 6: Late decrypt
- When a public key for a node becomes known (`handleNodeInfoPacket` / `handleNodeInfo`, and after our private key is loaded): `take(for:)` the pending entries, run `PkiDecryptionService.shared.tryDecrypt`, and for each success dispatch by portnum: text → update the existing placeholder message in place (text, clear `cipher`, clear the placeholder flag) in `AppState` **and** Core Data; NodeInfo/position/telemetry → the normal handlers.
- After hydration from Core Data, re-create buffer entries for stored messages that still have `cipher` (so restart does not lose them).
- 🔑 button in `MessageBubbleView` for `canRetryDecrypt` messages: retries decryption with the currently known key, and if that fails sends a forced NodeInfo request.

### Step 7: Retroactive names
In `AppState.upsertNode`, when a node's name changes from the placeholder to a real name, update the `from`/sender-name field of existing channel messages and the DM conversation title for that node id (read `MessageItem` and `DirectMessageConversation` for the actual property names; update only display-name strings).

**Verify (after each step)**: `swift build` exit 0. After step 5: app build succeeds.

## Test plan

`LateDecryptTests.swift`:
- Buffer: cap of 20, TTL 30 min, `take` empties the node's entries.
- Throttle: second request for the same node within 2 min denied; a different node within 8 s denied; `force` allowed.
- End-to-end with two CryptoKit key pairs: `encryptForTesting` blob (plan 003) buffered while the sender key is unknown → after supplying the key, decrypt yields the original `Meshtastic_Data`.
- Persistence round trip of `cipher` (if the persistence tests can run under SPM without the compiled model, follow how `PersistenceTests.swift` builds its model; if they build the model programmatically, add the attribute there too).

**Verify**: `swift test --filter LateDecrypt` → pass; `swift test` → all pass.

## Done criteria

- [ ] `swift test` exits 0; xcodebuild Debug build succeeds (model compiles)
- [ ] A new `.xcdatamodel` version exists and is current; the old version is unchanged
- [ ] Encrypted unicasts to other nodes no longer create chat items (covered by a test of the routing decision extracted as a pure function)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- The persistence layer does not use lightweight migration or the tests construct the model in a way that cannot include a new attribute.
- `AESCCM`-based `tryDecrypt` (plan 003) is missing.
- Updating a message in place is not supported by `AppState`/`MeshCoreDataStore` without re-inserting (duplicate risk).

## Maintenance notes

- Cipher blobs are sensitive only in combination with private keys; they are stored unencrypted in Core Data like message text.
- Automatic NodeInfo requests cost airtime — the throttle constants are deliberately conservative; do not lower them.
- Not verified on air. Reviewer: receive a DM from a node unknown to the client and confirm it turns readable after its NodeInfo arrives.
