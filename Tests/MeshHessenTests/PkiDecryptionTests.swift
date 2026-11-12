import CryptoKit
import Foundation
import Testing

@testable import MeshHessen

/// `PkiDecryptionService.shared` is a singleton holding the private key, so every
/// test loads its own freshly generated key and clears it again; the suite runs serialized.
@Suite("PkiDecryption", .serialized)
struct PkiDecryptionTests {
    private let service = PkiDecryptionService.shared
    private let fromNode: UInt32 = 0xA1B2_C3D4
    private let packetId: UInt32 = 0x1234_5678
    private let extraNonce: UInt32 = 0xDEAD_BEEF
    private let plaintext = Data("Hallo Mesh Hessen".utf8)

    @Test("Blob from encryptForTesting decrypts with the recipient's key")
    func roundTripViaService() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        defer { service.clearPrivateKey() }

        service.setPrivateKey(sender.rawRepresentation)
        let blob = try #require(service.encryptForTesting(
            plaintext: plaintext,
            recipientPublicKey: recipient.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId,
            extraNonce: extraNonce
        ))
        #expect(blob.count == plaintext.count + 8 + 4)

        service.setPrivateKey(recipient.rawRepresentation)
        let decrypted = service.tryDecrypt(
            ciphertext: blob,
            senderPublicKey: sender.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        )
        #expect(decrypted == plaintext)
    }

    @Test("Blob built independently with the firmware layout decrypts")
    func roundTripViaIndependentLayout() throws {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        defer { service.clearPrivateKey() }

        let shared = try sender.sharedSecretFromKeyAgreement(with: recipient.publicKey)
        let aesKey = Data(SHA256.hash(data: shared.withUnsafeBytes { Data($0) }))
        // [packetId LE 4][extraNonce LE 4][fromNode LE 4][0]
        let nonce = littleEndian(packetId) + littleEndian(extraNonce) + littleEndian(fromNode) + Data([0])
        let sealed = try #require(AESCCM.seal(key: aesKey, nonce: nonce, plaintext: plaintext, tagLength: 8))
        let blob = sealed + littleEndian(extraNonce)

        service.setPrivateKey(recipient.rawRepresentation)
        let decrypted = service.tryDecrypt(
            ciphertext: blob,
            senderPublicKey: sender.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        )
        #expect(decrypted == plaintext)
    }

    @Test("Wrong sender key returns nil")
    func wrongSenderKey() throws {
        let fixture = try makeBlob()
        defer { service.clearPrivateKey() }
        let stranger = Curve25519.KeyAgreement.PrivateKey()

        service.setPrivateKey(fixture.recipient.rawRepresentation)
        #expect(service.tryDecrypt(
            ciphertext: fixture.blob,
            senderPublicKey: stranger.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        ) == nil)
    }

    @Test("Blob with a flipped byte returns nil")
    func flippedByte() throws {
        let fixture = try makeBlob()
        defer { service.clearPrivateKey() }
        var tampered = fixture.blob
        tampered[2] ^= 0x01

        service.setPrivateKey(fixture.recipient.rawRepresentation)
        #expect(service.tryDecrypt(
            ciphertext: tampered,
            senderPublicKey: fixture.sender.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        ) == nil)
    }

    @Test("Wrong packet id or sender node returns nil")
    func wrongNonceInputs() throws {
        let fixture = try makeBlob()
        defer { service.clearPrivateKey() }
        let senderKey = fixture.sender.publicKey.rawRepresentation

        service.setPrivateKey(fixture.recipient.rawRepresentation)
        #expect(service.tryDecrypt(
            ciphertext: fixture.blob, senderPublicKey: senderKey, fromNode: fromNode, packetId: packetId &+ 1
        ) == nil)
        #expect(service.tryDecrypt(
            ciphertext: fixture.blob, senderPublicKey: senderKey, fromNode: fromNode &+ 1, packetId: packetId
        ) == nil)
    }

    @Test("A 12-byte blob returns nil")
    func twelveByteBlob() {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        defer { service.clearPrivateKey() }

        service.setPrivateKey(recipient.rawRepresentation)
        #expect(service.tryDecrypt(
            ciphertext: Data(count: 12),
            senderPublicKey: sender.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        ) == nil)
    }

    @Test("Random bytes (old-style AES-CTR blob) return nil instead of garbage")
    func randomBytesRejected() {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        defer { service.clearPrivateKey() }

        service.setPrivateKey(recipient.rawRepresentation)
        for length in [13, 20, 64] {
            let random = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            #expect(service.tryDecrypt(
                ciphertext: random,
                senderPublicKey: sender.publicKey.rawRepresentation,
                fromNode: fromNode,
                packetId: packetId
            ) == nil)
        }
    }

    @Test("No private key loaded returns nil")
    func noPrivateKey() throws {
        let fixture = try makeBlob()
        service.clearPrivateKey()
        #expect(!service.hasPrivateKey)
        #expect(service.tryDecrypt(
            ciphertext: fixture.blob,
            senderPublicKey: fixture.sender.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId
        ) == nil)
    }

    // MARK: - Helpers

    private struct BlobFixture {
        let sender: Curve25519.KeyAgreement.PrivateKey
        let recipient: Curve25519.KeyAgreement.PrivateKey
        let blob: Data
    }

    /// Creates a valid blob from a fresh sender to a fresh recipient, then clears the key.
    private func makeBlob() throws -> BlobFixture {
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        service.setPrivateKey(sender.rawRepresentation)
        defer { service.clearPrivateKey() }
        let blob = try #require(service.encryptForTesting(
            plaintext: plaintext,
            recipientPublicKey: recipient.publicKey.rawRepresentation,
            fromNode: fromNode,
            packetId: packetId,
            extraNonce: extraNonce
        ))
        return BlobFixture(sender: sender, recipient: recipient, blob: blob)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
