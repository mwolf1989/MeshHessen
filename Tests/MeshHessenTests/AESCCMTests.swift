import Foundation
import Testing

@testable import MeshHessen

@Suite("AESCCM")
struct AESCCMTests {
    // MARK: - RFC 3610 Packet Vector #1

    private let rfcKey = hex("C0C1C2C3C4C5C6C7C8C9CACBCCCDCECF")
    private let rfcNonce = hex("00000003020100A0A1A2A3A4A5")
    private let rfcAAD = hex("0001020304050607")
    private let rfcPlaintext = hex("08090A0B0C0D0E0F101112131415161718191A1B1C1D1E")
    private let rfcSealed = hex("588C979A61C663D2F066D0C2C0F989806D5F6B61DAC38417E8D12CFDF926E0")

    @Test("RFC 3610 packet vector #1 seals to the published ciphertext and tag")
    func rfcVectorSeal() {
        let sealed = AESCCM.seal(key: rfcKey, nonce: rfcNonce, plaintext: rfcPlaintext, aad: rfcAAD, tagLength: 8)
        #expect(sealed == rfcSealed)
    }

    @Test("RFC 3610 packet vector #1 opens to the published plaintext")
    func rfcVectorOpen() {
        let opened = AESCCM.open(key: rfcKey, nonce: rfcNonce, ciphertextAndTag: rfcSealed, aad: rfcAAD, tagLength: 8)
        #expect(opened == rfcPlaintext)
    }

    // MARK: - Round trip

    @Test(
        "Round trip with a 32-byte key",
        arguments: [0, 1, 15, 16, 17, 100], [8, 12]
    )
    func roundTrip(length: Int, tagLength: Int) throws {
        let key = randomBytes(32)
        let nonce = randomBytes(13)
        let plaintext = randomBytes(length)

        for aad in [Data(), randomBytes(8)] {
            let sealed = try #require(
                AESCCM.seal(key: key, nonce: nonce, plaintext: plaintext, aad: aad, tagLength: tagLength)
            )
            #expect(sealed.count == length + tagLength)
            let opened = AESCCM.open(key: key, nonce: nonce, ciphertextAndTag: sealed, aad: aad, tagLength: tagLength)
            #expect(opened == plaintext)
        }
    }

    // MARK: - Tampering

    @Test("Flipping a ciphertext byte fails verification")
    func tamperCiphertext() throws {
        let fixture = try TamperFixture()
        var sealed = fixture.sealed
        sealed[0] ^= 0x01
        #expect(fixture.open(sealed: sealed) == nil)
    }

    @Test("Flipping a tag byte fails verification")
    func tamperTag() throws {
        let fixture = try TamperFixture()
        var sealed = fixture.sealed
        sealed[sealed.count - 1] ^= 0x80
        #expect(fixture.open(sealed: sealed) == nil)
    }

    @Test("Flipping a nonce byte fails verification")
    func tamperNonce() throws {
        let fixture = try TamperFixture()
        var nonce = fixture.nonce
        nonce[5] ^= 0x01
        #expect(fixture.open(sealed: fixture.sealed, nonce: nonce) == nil)
    }

    @Test("Flipping an AAD byte fails verification")
    func tamperAAD() throws {
        let fixture = try TamperFixture()
        var aad = fixture.aad
        aad[3] ^= 0x01
        #expect(fixture.open(sealed: fixture.sealed, aad: aad) == nil)
    }

    @Test("Untampered fixture still opens")
    func untamperedOpens() throws {
        let fixture = try TamperFixture()
        #expect(fixture.open(sealed: fixture.sealed) == fixture.plaintext)
    }

    // MARK: - Input validation

    @Test("Invalid nonce, key or tag lengths are rejected")
    func invalidParameters() {
        let key = randomBytes(32)
        let nonce = randomBytes(13)
        let plaintext = randomBytes(10)
        #expect(AESCCM.seal(key: key, nonce: randomBytes(12), plaintext: plaintext, tagLength: 8) == nil)
        #expect(AESCCM.seal(key: randomBytes(20), nonce: nonce, plaintext: plaintext, tagLength: 8) == nil)
        #expect(AESCCM.seal(key: key, nonce: nonce, plaintext: plaintext, tagLength: 7) == nil)
        #expect(AESCCM.seal(key: key, nonce: nonce, plaintext: plaintext, tagLength: 18) == nil)
        #expect(AESCCM.open(key: key, nonce: nonce, ciphertextAndTag: randomBytes(4), tagLength: 8) == nil)
    }
}

// MARK: - Helpers

private struct TamperFixture {
    let key = randomBytes(32)
    let nonce = randomBytes(13)
    let aad = randomBytes(8)
    let plaintext = randomBytes(40)
    let sealed: Data

    init() throws {
        sealed = try #require(AESCCM.seal(key: key, nonce: nonce, plaintext: plaintext, aad: aad, tagLength: 8))
    }

    func open(sealed: Data, nonce: Data? = nil, aad: Data? = nil) -> Data? {
        AESCCM.open(
            key: key,
            nonce: nonce ?? self.nonce,
            ciphertextAndTag: sealed,
            aad: aad ?? self.aad,
            tagLength: 8
        )
    }
}

private func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}
