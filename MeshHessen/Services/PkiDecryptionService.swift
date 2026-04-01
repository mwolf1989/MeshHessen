import Foundation
import CryptoKit
import CommonCrypto

/// Client-side PKI decryption for Meshtastic encrypted packets.
/// Uses X25519 ECDH + SHA256 + AES-256-CTR matching the Meshtastic firmware implementation.
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

    /// Attempts to decrypt a PKI-encrypted packet.
    ///
    /// Algorithm (matching Meshtastic firmware):
    /// 1. SharedSecret = X25519(ourPrivateKey, senderPublicKey)
    /// 2. AesKey = SHA256(SharedSecret)
    /// 3. Nonce = [packetId 8B LE] + [fromNode 4B LE] + [0x00 × 4]
    /// 4. Plaintext = AES-256-CTR(AesKey, Nonce, ciphertext)
    ///
    /// - Returns: Decrypted data, or nil if decryption fails.
    func tryDecrypt(ciphertext: Data, senderPublicKey: Data, fromNode: UInt32, packetId: UInt32) -> Data? {
        guard !ciphertext.isEmpty else { return nil }
        guard senderPublicKey.count == 32 else {
            AppLogger.shared.log("[PKI] Invalid sender public key length: \(senderPublicKey.count)", debug: true)
            return nil
        }

        let privKey: Curve25519.KeyAgreement.PrivateKey? = lock.withLock { privateKey }
        guard let privKey else {
            AppLogger.shared.log("[PKI] No private key loaded", debug: true)
            return nil
        }

        // 1. Construct sender's public key
        guard let senderPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublicKey) else {
            AppLogger.shared.log("[PKI] Invalid sender public key", debug: true)
            return nil
        }

        // 2. X25519 key agreement → shared secret
        guard let sharedSecret = try? privKey.sharedSecretFromKeyAgreement(with: senderPubKey) else {
            AppLogger.shared.log("[PKI] Key agreement failed", debug: true)
            return nil
        }

        // 3. SHA256(sharedSecret) → AES key
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let aesKey = Data(SHA256.hash(data: sharedSecretData))

        // 4. Build nonce: [packetId 8B LE] + [fromNode 4B LE] + [0x00 × 4]
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt64(packetId).littleEndian, as: UInt64.self)
            ptr.storeBytes(of: fromNode.littleEndian, toByteOffset: 8, as: UInt32.self)
            // Bytes 12-15 are already zero
        }

        // 5. AES-256-CTR decrypt
        guard let plaintext = aesCTRDecrypt(key: aesKey, nonce: nonce, ciphertext: ciphertext) else {
            AppLogger.shared.log("[PKI] AES-256-CTR decryption failed", debug: true)
            return nil
        }

        return plaintext
    }

    // MARK: - AES-256-CTR

    /// AES-256-CTR decryption using CommonCrypto.
    private func aesCTRDecrypt(key: Data, nonce: Data, ciphertext: Data) -> Data? {
        guard key.count == 32, nonce.count == 16 else { return nil }

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            nonce.withUnsafeBytes { noncePtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    noncePtr.baseAddress,
                    keyPtr.baseAddress,
                    key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        let outputSize = ciphertext.count
        var output = Data(count: outputSize)
        var dataOutMoved = 0

        let updateStatus = output.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { inPtr in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress, ciphertext.count,
                    outPtr.baseAddress, outputSize,
                    &dataOutMoved
                )
            }
        }

        guard updateStatus == kCCSuccess else { return nil }
        output.count = dataOutMoved

        // Finalize (CTR mode: no additional output expected)
        var finalMoved = 0
        let finalBufSize = 16
        var finalBuf = Data(count: finalBufSize)
        let finalStatus = finalBuf.withUnsafeMutableBytes { ptr in
            CCCryptorFinal(cryptor, ptr.baseAddress, finalBufSize, &finalMoved)
        }
        if finalStatus == kCCSuccess && finalMoved > 0 {
            output.append(finalBuf.prefix(finalMoved))
        }

        return output
    }
}
