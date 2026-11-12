# Plan 015: Channel packets the radio could not decrypt are decrypted by the client (PSK and AEAD); traceroute can be sent RF-only

> **Executor instructions**: Follow this plan step by step. Run every verification command before moving on. If anything in "STOP conditions" occurs, stop and report. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/MeshtasticProtocolService.swift MeshHessen/Services/PkiDecryptionService.swift MeshHessen/Views/TracerouteSheet.swift`

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/003-pki-aes-ccm-decryption.md (hard — provides `AESCCM`), plans/001 (raw channel cache), plans/002 (only for the AEAD part)
- **Category**: direction (feature parity with Windows 1.6.2 / 1.6.4.6 / 1.7.2)
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Packets that reach the radio via MQTT on a channel whose downlink the radio does not decrypt arrive at the client still encrypted. Windows decrypts them itself with the channel keys it already knows (1.6.2), including firmware-2.8 AEAD channels (1.7.2), so these messages appear as normal chat instead of "encrypted message" placeholders. The same primitives enable an "RF only" traceroute (1.6.4.6): the client pre-encrypts the request and clears the `ok_to_mqtt` bit so MQTT gateways will not forward it, giving an honest radio-path measurement.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing).
- Reference (READ-ONLY, **authoritative**): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/MeshtasticProtocolService.cs` (live path ~1448–1464; helpers ~1766–1896: `DefaultPsk`, `ExpandChannelKey`, `EffectiveChannelName`, `ChannelHash`, `TryChannelDecrypt`, `AesCtrCrypt`; HF-only traceroute ~2350–2410), `MeshhessenClient/Services/ChannelAead.cs`, `MeshhessenClient.Tests/ChannelDecryptTests.cs`, `MeshhessenClient.Tests/ProtobufV28FeatureTests.cs`.
- Never copy key material into logs, tests or comments other than the publicly documented Meshtastic default channel key that the C# source defines as `DefaultPsk` — port that constant from the C# file; do not print it.

## Current state

- `handleMeshPacket` in `MeshHessen/Services/MeshtasticProtocolService.swift`: the `.encrypted(let ciphertext)` branch (~668) tries PKI (after plan 003: for packets addressed to us) and otherwise calls `handleEncryptedPacket(packet)` (~805), which creates placeholder messages.
- AES-CTR exists as a private helper in `PkiDecryptionService.swift` (or, after plan 003, as `AESCTR.crypt` in `MeshHessen/Services/AESCCM.swift`): `CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, …, kCCModeOptionCTR_BE)` with a 16-byte IV.
- Raw channel protos of the local node: `rawChannels` cache from plan 001 (if absent, `tempChannels.activeChannels` after a completed snapshot).
- LoRa config (for the preset name of unnamed channels) is in `receivedConfigs[.lora]` (~1289).
- `sendTraceroute` (~1737) builds the normal traceroute request; UI in `MeshHessen/Views/TracerouteSheet.swift`.

Algorithms (verify against the C# before coding):
- **Key expansion**: PSK length 0 → no encryption; length 1 → alias: the default key with its last byte incremented by `alias - 1` (alias 0 = no crypto); length 16 or 32 → used directly.
- **Effective channel name**: the configured name, or if empty the modem-preset name: `ShortTurbo`, `ShortSlow`, `ShortFast`, `MediumSlow`, `MediumFast`, `LongSlow`, `LongMod` (for LongModerate), `LongFast` (default / unknown), `Custom` when `use_preset` is off — port the full table from `EffectiveChannelName`.
- **Channel hash** (1 byte, carried in `packet.channel` of encrypted packets): XOR of all UTF-8 bytes of the effective name XOR all bytes of the expanded key.
- **CTR nonce** (16 bytes): `[packetId as UInt64 LE][fromNode UInt32 LE][0,0,0,0]`; AES-128 or AES-256 by key length.
- **AEAD channels** (`settings.useAead`): AES-CCM, **12-byte tag** appended to the ciphertext; 13-byte nonce `[packetId UInt64 LE][fromNode UInt32 LE][0x00]`; AAD (8 bytes) `[fromNode LE][toNode LE]`.
- **Acceptance**: decrypted bytes must parse as `Meshtastic_Data` with `portnum != .unknownApp` (CTR has no integrity check); CCM additionally verifies the tag.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter ChannelCrypto` | all pass |
| All tests | `swift test` | all pass |
| App build | `xcodebuild -project MeshHessen.xcodeproj -scheme MeshHessen -configuration Debug build` | `** BUILD SUCCEEDED **` |

## Scope

**In scope**: `MeshHessen/Services/ChannelCryptoService.swift` (create), the three files in the drift check, `MeshHessen/Services/AESCCM.swift` (only to expose CTR), `MeshHessen/Localizable.xcstrings`, `Tests/MeshHessenTests/ChannelCryptoTests.swift` (create).

**Out of scope**: late PKI decryption (plan 016); sending normal chat messages pre-encrypted; changing how the radio is configured.

## Git workflow

Branch `feat/015-channel-crypto`. Conventional commits. Do not push.

## Steps

### Step 1: Pure crypto helpers
`ChannelCryptoService.swift` — an `enum ChannelCrypto` with static functions: `expandKey(_ psk: Data) -> Data?`, `effectiveName(settingsName:usePreset:modemPreset:) -> String`, `hash(name:key:) -> UInt8`, `decryptCTR/encryptCTR`, `decryptAEAD/encryptAEAD` (via `AESCCM`, tagLength 12), and
```swift
struct KnownChannel { let index: Int; let name: String; let key: Data; let useAead: Bool }
static func tryDecrypt(ciphertext: Data, channelHash: UInt32, packetId: UInt32, from: UInt32, to: UInt32, channels: [KnownChannel]) -> (data: Meshtastic_Data, channelIndex: Int)?
```
`tryDecrypt` first tries channels whose hash matches; port the optional brute-force-over-all-channels fallback only if the C# does it unconditionally.

Port the test vectors from `ChannelDecryptTests.cs` / `ProtobufV28FeatureTests.cs` into `ChannelCryptoTests.swift` (hash values for known name+key pairs, CTR round trip, AEAD round trip, AEAD tamper detection, alias expansion).

**Verify**: `swift test --filter ChannelCrypto` → all pass.

### Step 2: Live decrypt path
In the `.encrypted` branch, after the PKI attempt and before `handleEncryptedPacket(packet)`: if the packet is not addressed to us as a unicast PKI candidate (or PKI failed), build `[KnownChannel]` from the raw channel cache + LoRa config and call `tryDecrypt`. On success copy the packet, set `decoded`, set `channel = UInt32(channelIndex)`, log at debug level, and re-dispatch through the **same** portnum switch the PKI block uses (refactor that inner switch into one private function `dispatchDecoded(_ data:packet:)` used by the normal path, PKI path and this path — pure extraction, no behaviour change).

**Verify**: `swift build` exit 0; `swift test` → all pass.

### Step 3: RF-only traceroute
- `MeshtasticProtocolService`: `func sendTraceroute(…, rfOnly: Bool = false)`. When `rfOnly`: build `Meshtastic_Data` (portnum traceroute, empty `RouteDiscovery`, `wantResponse = true`, `bitfield = 1 << 1` — bit 0 is OK_TO_MQTT and stays cleared, bit 1 mirrors want_response; confirm the exact value in the C# `TrySendHfOnlyTracerouteAsync`), encrypt with the primary channel (CTR or AEAD), build a `MeshPacket` with `.encrypted`, `channel = hash` (abort to the normal path if the hash is 0 or the primary key is unknown), `hopLimit = hopStart = 7`, random non-zero id, and send via the existing raw send. Register the packet id wherever normal traceroutes register theirs so the response is matched.
- `TracerouteSheet.swift`: a toggle "RF only (do not route via MQTT)" with `.help` explaining it; passes `rfOnly`.

**Verify**: app build succeeds.

## Done criteria

- [ ] `swift test` exits 0 including `ChannelCrypto` suite; xcodebuild Debug build succeeds
- [ ] The portnum dispatch exists once (`grep -c "case .textMessageApp:" MeshHessen/Services/MeshtasticProtocolService.swift` → 1)
- [ ] No key bytes appear in log statements (`grep -n "psk" MeshHessen/Services/ChannelCryptoService.swift` shows no `AppLogger` lines printing key data)
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `AESCCM` (plan 003) is missing.
- A ported Windows test vector fails after two fix attempts — report expected vs. actual hex.
- Decrypting successfully would create duplicate chat messages because the radio also delivered a decoded copy (check for an existing de-duplication by packet id in `handleTextMessage`; if none exists, STOP and report).

## Maintenance notes

- CTR decryption has no integrity check; the `Meshtastic_Data` parse + portnum check is the only filter, exactly as on Windows.
- Not verified on air. Reviewer: enable MQTT downlink for a channel on the broker side only, send from another node via MQTT, confirm clear text appears; run an RF-only traceroute and confirm no MQTT hop appears.
