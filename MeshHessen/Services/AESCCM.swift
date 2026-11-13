import CommonCrypto
import Foundation

/// AES-CCM (RFC 3610 / NIST SP 800-38C) with a 13-byte nonce (L = 2).
///
/// Neither CryptoKit nor CommonCrypto exposes CCM, so it is built here on top of
/// single-block AES-ECB from CommonCrypto. Accepts 16-, 24- and 32-byte keys.
/// Used by Meshtastic PKC direct messages (AES-256, 8-byte tag, no AAD).
enum AESCCM {
    private static let blockSize = kCCBlockSizeAES128
    private static let nonceLength = 13
    private static let lengthFieldSize = 2 // L

    /// Returns ciphertext ‖ tag. nonce must be 13 bytes (L = 2); tagLength 4...16 even.
    static func seal(key: Data, nonce: Data, plaintext: Data, aad: Data = Data(), tagLength: Int) -> Data? {
        guard validate(key: key, nonce: nonce, messageLength: plaintext.count, aad: aad, tagLength: tagLength) else {
            return nil
        }
        guard let mac = cbcMAC(key: key, nonce: nonce, message: plaintext, aad: aad, tagLength: tagLength),
              let s0 = encryptBlock(key: key, block: counterBlock(nonce: nonce, counter: 0)),
              let ciphertext = ctrKeystreamXor(key: key, nonce: nonce, data: plaintext) else {
            return nil
        }
        var tag = Data(count: tagLength)
        for i in 0..<tagLength {
            tag[i] = mac[i] ^ s0[i]
        }
        return ciphertext + tag
    }

    /// Input is ciphertext ‖ tag. Returns nil when the tag does not verify.
    static func open(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data = Data(), tagLength: Int) -> Data? {
        let input = Data(ciphertextAndTag) // re-base indices to 0
        guard input.count >= tagLength else { return nil }
        let ciphertext = input.prefix(input.count - tagLength)
        let receivedTag = input.suffix(tagLength)
        guard validate(key: key, nonce: nonce, messageLength: ciphertext.count, aad: aad, tagLength: tagLength) else {
            return nil
        }
        guard let plaintext = ctrKeystreamXor(key: key, nonce: nonce, data: Data(ciphertext)),
              let mac = cbcMAC(key: key, nonce: nonce, message: plaintext, aad: aad, tagLength: tagLength),
              let s0 = encryptBlock(key: key, block: counterBlock(nonce: nonce, counter: 0)) else {
            return nil
        }
        // Constant-time comparison: no early exit.
        var diff: UInt8 = 0
        for (i, received) in receivedTag.enumerated() {
            diff |= received ^ (mac[i] ^ s0[i])
        }
        return diff == 0 ? plaintext : nil
    }

    // MARK: - Private

    private static func validate(key: Data, nonce: Data, messageLength: Int, aad: Data, tagLength: Int) -> Bool {
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else { return false }
        guard nonce.count == nonceLength else { return false }
        guard (4...16).contains(tagLength), tagLength % 2 == 0 else { return false }
        guard messageLength < (1 << (8 * lengthFieldSize)) else { return false }
        // Only the 2-byte AAD length encoding is supported (aad length < 2^16 - 2^8).
        guard aad.count < 0xFF00 else { return false }
        return true
    }

    /// CBC-MAC over B0 ‖ encoded AAD ‖ message, truncated to `tagLength` bytes.
    private static func cbcMAC(key: Data, nonce: Data, message: Data, aad: Data, tagLength: Int) -> Data? {
        var flags = UInt8(((tagLength - 2) / 2) << 3) | UInt8(lengthFieldSize - 1)
        if !aad.isEmpty { flags |= 0x40 }

        var b0 = Data([flags])
        b0.append(nonce)
        b0.append(UInt8((message.count >> 8) & 0xFF))
        b0.append(UInt8(message.count & 0xFF))

        var macInput = b0
        if !aad.isEmpty {
            var encodedAAD = Data([UInt8((aad.count >> 8) & 0xFF), UInt8(aad.count & 0xFF)])
            encodedAAD.append(aad)
            macInput.append(zeroPadded(encodedAAD))
        }
        macInput.append(zeroPadded(message))

        var x = Data(count: blockSize)
        var offset = macInput.startIndex
        while offset < macInput.endIndex {
            var block = Data(count: blockSize)
            for i in 0..<blockSize {
                block[i] = x[i] ^ macInput[offset + i]
            }
            guard let encrypted = encryptBlock(key: key, block: block) else { return nil }
            x = encrypted
            offset += blockSize
        }
        return x.prefix(tagLength)
    }

    /// XORs `data` with the keystream S_1, S_2, … (CCM counter mode, starting at counter 1).
    private static func ctrKeystreamXor(key: Data, nonce: Data, data: Data) -> Data? {
        let input = Data(data)
        var output = Data(count: input.count)
        var counter = 1
        var offset = 0
        while offset < input.count {
            guard let keystream = encryptBlock(key: key, block: counterBlock(nonce: nonce, counter: counter)) else {
                return nil
            }
            let chunk = min(blockSize, input.count - offset)
            for i in 0..<chunk {
                output[offset + i] = input[offset + i] ^ keystream[i]
            }
            offset += chunk
            counter += 1
        }
        return output
    }

    /// A_i = [flags = L - 1] ‖ nonce ‖ i (2 bytes big-endian).
    private static func counterBlock(nonce: Data, counter: Int) -> Data {
        var block = Data([UInt8(lengthFieldSize - 1)])
        block.append(nonce)
        block.append(UInt8((counter >> 8) & 0xFF))
        block.append(UInt8(counter & 0xFF))
        return block
    }

    private static func zeroPadded(_ data: Data) -> Data {
        var padded = Data(data)
        let remainder = padded.count % blockSize
        if remainder != 0 {
            padded.append(Data(count: blockSize - remainder))
        }
        return padded
    }

    /// E(K, block): one AES block in ECB mode.
    private static func encryptBlock(key: Data, block: Data) -> Data? {
        guard block.count == blockSize else { return nil }
        var output = Data(count: blockSize)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            block.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, blockSize,
                        outPtr.baseAddress, blockSize,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == blockSize else { return nil }
        return output
    }
}

/// AES-CTR with a 16-byte big-endian counter block (Meshtastic channel PSK scheme).
/// Used by client-side channel decryption (`ChannelCrypto`).
enum AESCTR {
    /// AES-128- or AES-256-CTR using CommonCrypto (key length 16 or 32).
    /// Encryption and decryption are the same operation.
    static func crypt(key: Data, nonce: Data, ciphertext: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256, nonce.count == 16 else { return nil }

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
