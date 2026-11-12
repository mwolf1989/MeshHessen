import CryptoKit
import Foundation

/// Client-side PKI decryption for Meshtastic encrypted packets.
/// Uses X25519 ECDH + SHA256 + AES-256-CCM (8-byte tag) matching the Meshtastic firmware implementation.
///
/// Security: The private key is held in RAM only, never persisted to disk,
/// and zeroed on disconnect via `clearPrivateKey()`.
final class PkiDecryptionService: @unchecked Sendable {
    static let shared = PkiDecryptionService()

    private let lock = NSLock()
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?

    private init() {}

    /// Stores the device's private key (32 bytes from SecurityConfig).
    /// Must only be called after reading the config, never persisted.
    func setPrivateKey(_ keyData: Data) {
        guard keyData.count == 32 else {
            AppLogger.shared.log("[PKI] Invalid private key length: \(keyData.count) (expected 32)", debug: true)
            return
        }
        lock.withLock {
            privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        }
        if lock.withLock({ privateKey }) != nil {
            AppLogger.shared.log("[PKI] Private key loaded (\(keyData.count) bytes)", debug: true)
        } else {
            AppLogger.shared.log("[PKI] Failed to create private key from data")
        }
    }

    /// Securely clears the private key from memory. Call on disconnect.
    func clearPrivateKey() {
        lock.withLock {
            privateKey = nil
        }
        AppLogger.shared.log("[PKI] Private key cleared", debug: true)
    }

    /// Whether a private key is currently loaded.
    var hasPrivateKey: Bool {
        lock.withLock { privateKey != nil }
    }

    /// Attempts to decrypt a PKI-encrypted (PKC) direct message.
    ///
    /// Algorithm (matching Meshtastic firmware `CryptoEngine::decryptCurve25519`):
    /// 1. SharedSecret = X25519(ourPrivateKey, senderPublicKey)
    /// 2. AesKey = SHA256(SharedSecret)
    /// 3. On-wire blob = ciphertext ‖ tag (8 bytes) ‖ extraNonce (4 bytes LE)
    /// 4. Nonce (13 bytes) = [packetId 4B LE] + [extraNonce 4B LE] + [fromNode 4B LE] + [0x00]
    /// 5. Plaintext = AES-256-CCM open (tag length 8, no associated data)
    ///
    /// - Parameter ciphertext: The full on-wire blob (ciphertext ‖ tag ‖ extraNonce).
    /// - Returns: Tag-verified plaintext, or nil if the key is missing, the blob is
    ///   malformed, or the tag does not verify (wrong key / not a PKC packet).
    func tryDecrypt(ciphertext: Data, senderPublicKey: Data, fromNode: UInt32, packetId: UInt32) -> Data? {
        let blob = Data(ciphertext)
        guard blob.count > 12 else { return nil }
        guard let aesKey = deriveKey(otherPublicKey: senderPublicKey) else { return nil }

        let extraNonce = Data(blob.suffix(4))
        let nonce = buildNonce(packetId: packetId, fromNode: fromNode, extraNonce: extraNonce)
        let body = Data(blob.dropLast(4))

        guard let plaintext = AESCCM.open(key: aesKey, nonce: nonce, ciphertextAndTag: body, tagLength: 8) else {
            // Expected for packets that are not PKC or were encrypted for someone else.
            AppLogger.shared.log("[PKI] AES-256-CCM tag verification failed", debug: true)
            return nil
        }
        return plaintext
    }

    /// Produces a PKC blob (ciphertext ‖ 8-byte tag ‖ extraNonce LE) for `plaintext`
    /// addressed to `recipientPublicKey`, using the currently loaded private key.
    /// Mirrors the firmware's `encryptCurve25519`; used by round-trip tests only.
    func encryptForTesting(
        plaintext: Data,
        recipientPublicKey: Data,
        fromNode: UInt32,
        packetId: UInt32,
        extraNonce: UInt32
    ) -> Data? {
        guard let aesKey = deriveKey(otherPublicKey: recipientPublicKey) else { return nil }
        var extraNonceBytes = Data(count: 4)
        extraNonceBytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: extraNonce.littleEndian, as: UInt32.self)
        }
        let nonce = buildNonce(packetId: packetId, fromNode: fromNode, extraNonce: extraNonceBytes)
        guard let sealed = AESCCM.seal(key: aesKey, nonce: nonce, plaintext: plaintext, tagLength: 8) else {
            return nil
        }
        return sealed + extraNonceBytes
    }

    // MARK: - Private

    /// AES key = SHA256(X25519(ourPrivateKey, otherPublicKey)).
    private func deriveKey(otherPublicKey: Data) -> Data? {
        guard otherPublicKey.count == 32 else {
            AppLogger.shared.log("[PKI] Invalid sender public key length: \(otherPublicKey.count)", debug: true)
            return nil
        }

        let privKey: Curve25519.KeyAgreement.PrivateKey? = lock.withLock { privateKey }
        guard let privKey else {
            AppLogger.shared.log("[PKI] No private key loaded", debug: true)
            return nil
        }

        guard let otherPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: otherPublicKey) else {
            AppLogger.shared.log("[PKI] Invalid sender public key", debug: true)
            return nil
        }

        guard let sharedSecret = try? privKey.sharedSecretFromKeyAgreement(with: otherPubKey) else {
            AppLogger.shared.log("[PKI] Key agreement failed", debug: true)
            return nil
        }

        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        return Data(SHA256.hash(data: sharedSecretData))
    }

    /// 13-byte CCM nonce: [packetId 4B LE][extraNonce 4B, as on the wire][fromNode 4B LE][0x00].
    private func buildNonce(packetId: UInt32, fromNode: UInt32, extraNonce: Data) -> Data {
        var nonce = Data(count: 13)
        nonce.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: packetId.littleEndian, as: UInt32.self)
            ptr.storeBytes(of: fromNode.littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        nonce.replaceSubrange(4..<8, with: extraNonce)
        return nonce
    }
}
