# Plan 003: Client-side PKI decryption uses the firmware's AES-256-CCM scheme and is tried for every packet addressed to us

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving on. If anything in "STOP conditions" occurs, stop and report — do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat d470b3a..HEAD -- MeshHessen/Services/PkiDecryptionService.swift MeshHessen/Services/MeshtasticProtocolService.swift`

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (hand-written crypto mode; mitigated by known-answer tests)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `d470b3a`, 2026-11-12

## Why this matters

Direct messages between Meshtastic nodes are encrypted with public-key crypto (PKC). When the radio cannot decrypt one itself (typically packets arriving via MQTT), the client is supposed to do it. The Mac implements this with AES-CTR and a 16-byte nonce — that is the *channel* scheme, not the PKC scheme, so it can never decrypt a real PKC packet and produces garbage that then fails protobuf parsing. Windows fixed the identical bug in 1.6.2 by switching to AES-256-CCM with tag verification. Plans 015 (AEAD channels) and 016 (late decryption) build on the CCM primitive created here.

## Repo facts (read once)

- Target repo: `/Volumes/Dock/code/Private/mesh/MeshHessen` — macOS 14+ Swift/SwiftUI; tests in `Tests/MeshHessenTests/` (Swift Testing: `import Testing`, `@testable import MeshHessen`).
- Reference (READ-ONLY): `/Volumes/Dock/code/Private/mesh/mh_windowsclient` branch `firmware_update` (`095ea5b`): `MeshhessenClient/Services/PkiDecryptionService.cs`, `MeshhessenClient.Tests/PkiLateDecryptTests.cs`.
- Neither CryptoKit nor CommonCrypto exposes AES-CCM. CommonCrypto does expose single-block AES-ECB (`CCCrypt` with `kCCAlgorithmAES`, `kCCOptionECBMode`), which is all CCM needs. Do **not** add a third-party dependency.
- Conventions: 4-space indent, `AppLogger.shared.log(...)`, never edit `MeshHessen/Generated/`.

## Current state

`MeshHessen/Services/PkiDecryptionService.swift` `tryDecrypt(ciphertext:senderPublicKey:fromNode:packetId:)` (~57):
```swift
// 4. Build nonce: [packetId 8B LE] + [fromNode 4B LE] + [0x00 × 4]
var nonce = Data(count: 16)
...
// 5. AES-256-CTR decrypt
guard let plaintext = aesCTRDecrypt(key: aesKey, nonce: nonce, ciphertext: ciphertext) else {
```
Key derivation (X25519 → `SHA256(sharedSecret)`) in the same function is correct and stays.

`MeshHessen/Services/MeshtasticProtocolService.swift` `handleMeshPacket`, `.encrypted` branch (~675):
```swift
if packet.pkiEncrypted && PkiDecryptionService.shared.hasPrivateKey {
```
The firmware clears `pki_encrypted` whenever the local radio failed to decrypt, so this gate skips exactly the packets that need client-side decryption.

### Correct scheme (Windows `PkiDecryptionService.cs`, lines ~66–155)

- On-wire blob = `ciphertext ‖ tag(8 bytes) ‖ extraNonce(4 bytes, little-endian)`. Blobs of ≤ 12 bytes are invalid.
- Key = `SHA256(X25519(ourPrivate, senderPublic))` (32 bytes).
- Nonce (13 bytes, CCM with L = 2): bytes 0–3 = packetId (LE), bytes 4–7 = extraNonce (LE), bytes 8–11 = fromNode (LE), byte 12 = 0.
- AES-256-CCM, tag length M = 8, **no associated data**. A tag mismatch returns nil.

CCM per RFC 3610 / NIST SP 800-38C with L = 2, M = 8, no AAD:
- `B0 = [flags = ((M-2)/2) << 3 | (L-1) = 0x19] ‖ nonce(13) ‖ msgLen(2 bytes big-endian)`.
- CBC-MAC: `X1 = E(K, B0)`; for each 16-byte plaintext block (last block zero-padded) `X = E(K, X xor block)`; `T = first 8 bytes of X`.
- Counter blocks `A_i = [flags = L-1 = 0x01] ‖ nonce(13) ‖ i(2 bytes big-endian)`; `S_i = E(K, A_i)`.
- Ciphertext = plaintext xor `S_1, S_2, …`; transmitted tag = `T xor first 8 bytes of S_0`.
- Decrypt: recover plaintext with `S_1…`, recompute `T`, compare to `tag xor S_0` in constant time.

## Commands

| Purpose | Command | Expected |
|---|---|---|
| Build | `swift build` | exit 0 |
| Tests | `swift test --filter AESCCM` / `swift test --filter PkiDecryption` | all pass |
| All tests | `swift test` | all pass |

## Scope

**In scope**: `MeshHessen/Services/AESCCM.swift` (create), `MeshHessen/Services/PkiDecryptionService.swift`, the `.encrypted` branch of `handleMeshPacket` in `MeshHessen/Services/MeshtasticProtocolService.swift`, `Tests/MeshHessenTests/AESCCMTests.swift` and `Tests/MeshHessenTests/PkiDecryptionTests.swift` (create).

**Out of scope**: buffering undecryptable DMs / late decryption (plan 016); channel PSK decryption (plan 015); `NodeKeyService`. Keep the private `aesCTRDecrypt` helper only if something else still uses it; otherwise move it unchanged into `AESCCM.swift` as `AESCTR.crypt` for plan 015 (do not delete the logic).

## Git workflow

Branch `fix/003-pki-aes-ccm`. Conventional commits. Do not push.

## Steps

### Step 1: `AESCCM` primitive
Create `MeshHessen/Services/AESCCM.swift`:
```swift
enum AESCCM {
    /// Returns ciphertext ‖ tag. nonce must be 13 bytes (L = 2); tagLength 4...16 even.
    static func seal(key: Data, nonce: Data, plaintext: Data, aad: Data = Data(), tagLength: Int) -> Data?
    /// Input is ciphertext ‖ tag. Returns nil when the tag does not verify.
    static func open(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data = Data(), tagLength: Int) -> Data?
}
```
Implement AAD support too (plan 015 needs 8 bytes of AAD): when `aad` is non-empty set bit 6 (`0x40`) in the B0 flags and prepend the AAD blocks `[len(2 bytes BE)] ‖ aad`, zero-padded to 16-byte blocks, to the CBC-MAC input before the message blocks. Use `CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, …)` on one 16-byte block for `E(K, ·)`. Compare tags without early exit.

**Verify**: `swift build` exit 0.

### Step 2: Known-answer tests
`AESCCMTests.swift`:
- **RFC 3610 Packet Vector #1** (AES-128, L = 2, M = 8, with AAD — verified against the RFC text by the planner):
  - key `C0C1C2C3C4C5C6C7C8C9CACBCCCDCECF`
  - nonce `00000003020100A0A1A2A3A4A5`
  - aad `0001020304050607`
  - plaintext `08090A0B0C0D0E0F101112131415161718191A1B1C1D1E` (23 bytes)
  - `seal(..., tagLength: 8)` must equal `588C979A61C663D2F066D0C2C0F989806D5F6B61DAC38417` ‖ `E8D12CFDF926E0` (i.e. hex `588C979A61C663D2F066D0C2C0F989806D5F6B61DAC38417E8D12CFDF926E0`), and `open` of that must return the plaintext.
  - Intermediate values for debugging: B0 = `59000000030201 00A0A1A2A3A4A5 0017`, CBC-MAC = `2DC697E411CA83A8`, S0 prefix = `3A2E46C8EC33A548`.
  - `AESCCM` must therefore accept 16-byte keys as well as 32-byte keys.
- Round trip `open(seal(x)) == x` with a 32-byte key for plaintext lengths 0, 1, 15, 16, 17, 100, with and without AAD, tag lengths 8 and 12.
- Tamper tests: flipping one byte of ciphertext, tag, nonce or AAD makes `open` return nil.

**Verify**: `swift test --filter AESCCM` → all pass.

### Step 3: Fix `PkiDecryptionService.tryDecrypt`
Keep the signature (parameter `ciphertext` is the full blob). New body after key derivation:
```swift
guard blob.count > 12 else { return nil }
let extraNonce = blob.suffix(4)                       // LE bytes, used as-is
var nonce = Data(count: 13)                           // [id LE 4][extra 4][from LE 4][0]
let body = blob.dropLast(4)                           // ciphertext ‖ 8-byte tag
return AESCCM.open(key: aesKey, nonce: nonce, ciphertextAndTag: Data(body), tagLength: 8)
```
Add an `internal func encryptForTesting(plaintext:recipientPublicKey:fromNode:packetId:extraNonce:) -> Data?` mirroring Windows `Encrypt` (ciphertext ‖ tag ‖ extraNonce LE). Update the doc comment to describe the real algorithm. A failed tag check must not log at non-debug level (it is expected for non-PKC packets).

### Step 4: Try PKI for every encrypted packet addressed to us
In `handleMeshPacket` change the gate to:
```swift
if myNodeId != 0, packet.to == myNodeId, PkiDecryptionService.shared.hasPrivateKey {
```
Keep the rest of the block (sender key from `packet.publicKey`, else `NodeKeyService.shared.publicKey(for:)`; re-dispatch by portnum). Because `tryDecrypt` now verifies the tag, a nil result simply falls through to `handleEncryptedPacket(packet)` as before.

**Verify**: `swift build` exit 0.

### Step 5: Service tests
`PkiDecryptionTests.swift` (check how existing tests load a key — grep `setPrivateKey\|loadPrivateKey` in `PkiDecryptionService.swift`; `PkiDecryptionService.shared` is a singleton, so set and clear the key inside each test and mark the suite `.serialized`):
- Two CryptoKit `Curve25519.KeyAgreement.PrivateKey`s (A, B). Service holds B; blob created with A's private key via a second, local key agreement (or `encryptForTesting` after loading A, then switch to B) decrypts to the original plaintext.
- Wrong sender key → nil. Blob with a flipped byte → nil. 12-byte blob → nil.
- An old-style AES-CTR blob (any random bytes) → nil, not garbage.

**Verify**: `swift test --filter PkiDecryption` → pass; `swift test` → all pass.

## Done criteria

- [ ] `grep -n "kCCModeCTR" MeshHessen/Services/PkiDecryptionService.swift` → no matches inside `tryDecrypt`'s path
- [ ] `grep -n "packet.pkiEncrypted && PkiDecryptionService" MeshHessen/Services/MeshtasticProtocolService.swift` → no matches
- [ ] `swift test` exits 0 with the two new suites
- [ ] Only in-scope files changed; `plans/README.md` row updated

## STOP conditions

- `CCCrypt` in ECB mode is unavailable in the SPM build (import `CommonCrypto` fails).
- The Python-generated vector (if you could generate it) does not match your `seal` output after two fix attempts — report both hex strings.
- `PkiDecryptionService` has no way to inject a private key in tests.

## Maintenance notes

- Not verified against a real radio by the planner. Reviewer: send a PKC DM to this node via MQTT only and confirm it appears decrypted.
- `AESCCM` is reused by plan 015 (AEAD channels: 12-byte tag, 8-byte AAD) and plan 016.
