import Foundation

import SwiftProtobuf

/// Client-side Meshtastic channel crypto (pure functions, no state).
///
/// Packets relayed to the radio via MQTT on a channel whose downlink the radio does
/// not decrypt arrive still channel-encrypted. With the channel keys the client
/// already knows it can decrypt them itself (AES-CTR, or AES-CCM on firmware-2.8
/// AEAD channels), and it can pre-encrypt packets such as the RF-only traceroute.
///
/// Mirrors the Windows client (`MeshtasticProtocolService.cs`: `ExpandChannelKey`,
/// `EffectiveChannelName`, `ChannelHash`, `TryChannelDecrypt`, `AesCtrCrypt`;
/// `ChannelAead.cs`) and the firmware (`Channels::getKey`, `Channels::generateHash`,
/// `CryptoEngine::encryptPacketCCM`).
///
/// Never log key material from here.
enum ChannelCrypto {
    /// A channel the client holds the key for.
    struct KnownChannel: Equatable, Sendable {
        let index: Int
        /// Effective name (see `effectiveName`), the name the firmware hashes.
        let name: String
        /// Expanded key (16 or 32 bytes).
        let key: Data
        let useAead: Bool

        var hash: UInt8 { ChannelCrypto.hash(name: name, key: key) }
    }

    /// AEAD channels append a 12-byte CCM tag to the ciphertext.
    static let aeadTagLength = 12

    /// The publicly documented Meshtastic default channel key (alias index 1),
    /// from firmware `Channels.h`.
    static let defaultKey = Data([
        0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
        0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
    ])

    // MARK: - Keys and names

    /// Expands a channel PSK to the actual AES key (firmware `Channels::getKey`).
    /// - 0 bytes or alias 0 → nil (no encryption)
    /// - 1 byte (alias n ≥ 1) → the default key with its last byte increased by n - 1
    /// - 16 or 32 bytes → used as-is
    static func expandKey(_ psk: Data) -> Data? {
        let psk = Data(psk)
        switch psk.count {
        case 0:
            return nil
        case 1:
            let alias = psk[0]
            guard alias != 0 else { return nil }
            var key = defaultKey
            key[key.count - 1] = key[key.count - 1] &+ (alias &- 1)
            return key
        case 16, 32:
            return psk
        default:
            return nil
        }
    }

    /// The name the firmware hashes: the configured name, or for an unnamed channel the
    /// modem-preset display name (`Channels::getName`). `modemPreset == nil` means the
    /// LoRa config is unknown and falls back to "LongFast", like the Windows client.
    static func effectiveName(
        settingsName: String,
        usePreset: Bool,
        modemPreset: Meshtastic_Config.LoRaConfig.ModemPreset?
    ) -> String {
        if !settingsName.isEmpty { return settingsName }
        guard let modemPreset else { return "LongFast" }
        if !usePreset { return "Custom" }
        switch modemPreset {
        case .shortTurbo:   return "ShortTurbo"
        case .shortSlow:    return "ShortSlow"
        case .shortFast:    return "ShortFast"
        case .mediumSlow:   return "MediumSlow"
        case .mediumFast:   return "MediumFast"
        case .longSlow:     return "LongSlow"
        case .longModerate: return "LongMod"
        case .longFast:     return "LongFast"
        // Remaining presets: the enum name matches the firmware display name
        // (Windows uses `ModemPreset.ToString()` here).
        case .veryLongSlow: return "VeryLongSlow"
        case .longTurbo:    return "LongTurbo"
        case .liteFast:     return "LiteFast"
        case .liteSlow:     return "LiteSlow"
        case .narrowFast:   return "NarrowFast"
        case .narrowSlow:   return "NarrowSlow"
        case .tinyFast:     return "TinyFast"
        case .tinySlow:     return "TinySlow"
        case .mediumTurbo:  return "MediumTurbo"
        case .UNRECOGNIZED(let value): return String(value)
        }
    }

    /// One-byte channel hash carried in `MeshPacket.channel` of encrypted packets:
    /// XOR of the UTF-8 name bytes XOR all key bytes (`Channels::generateHash`).
    static func hash(name: String, key: Data) -> UInt8 {
        var h: UInt8 = 0
        for byte in Array(name.utf8) { h ^= byte }
        for byte in key { h ^= byte }
        return h
    }

    /// Builds the known-channel list from raw channel protos. Channels without a key
    /// (no encryption) are skipped.
    static func knownChannels(
        from channels: [Meshtastic_Channel],
        loraConfig: Meshtastic_Config.LoRaConfig?
    ) -> [KnownChannel] {
        channels
            .filter { $0.role != .disabled }
            .sorted { $0.index < $1.index }
            .compactMap { channel in
                guard let key = expandKey(channel.settings.psk) else { return nil }
                let name = effectiveName(
                    settingsName: channel.settings.name,
                    usePreset: loraConfig?.usePreset ?? true,
                    modemPreset: loraConfig?.modemPreset
                )
                return KnownChannel(
                    index: Int(channel.index),
                    name: name,
                    key: key,
                    useAead: channel.settings.useAead
                )
            }
    }

    // MARK: - AES-CTR (classic channels)

    /// 16-byte CTR nonce: [packetId as UInt64 LE][fromNode UInt32 LE][0, 0, 0, 0].
    static func ctrNonce(packetId: UInt32, fromNode: UInt32) -> Data {
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt64(packetId).littleEndian, as: UInt64.self)
            ptr.storeBytes(of: fromNode.littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        return nonce
    }

    static func decryptCTR(key: Data, packetId: UInt32, fromNode: UInt32, ciphertext: Data) -> Data? {
        guard !ciphertext.isEmpty else { return nil }
        return AESCTR.crypt(key: key, nonce: ctrNonce(packetId: packetId, fromNode: fromNode), ciphertext: Data(ciphertext))
    }

    static func encryptCTR(key: Data, packetId: UInt32, fromNode: UInt32, plaintext: Data) -> Data? {
        // CTR is symmetric.
        decryptCTR(key: key, packetId: packetId, fromNode: fromNode, ciphertext: plaintext)
    }

    // MARK: - AES-CCM (AEAD channels, firmware 2.8)

    /// 13-byte CCM nonce: [packetId as UInt64 LE][fromNode UInt32 LE][0x00].
    static func aeadNonce(packetId: UInt32, fromNode: UInt32) -> Data {
        Data(ctrNonce(packetId: packetId, fromNode: fromNode).prefix(13))
    }

    /// 8-byte AAD: [fromNode LE][toNode LE]. Hop fields stay out because relays rewrite them.
    static func aeadAAD(fromNode: UInt32, toNode: UInt32) -> Data {
        var aad = Data(count: 8)
        aad.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: fromNode.littleEndian, as: UInt32.self)
            ptr.storeBytes(of: toNode.littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return aad
    }

    /// Input is ciphertext ‖ 12-byte tag; nil on wrong key, tampering or a too-short input.
    static func decryptAEAD(key: Data, packetId: UInt32, fromNode: UInt32, toNode: UInt32, ciphertext: Data) -> Data? {
        guard ciphertext.count > aeadTagLength else { return nil }
        return AESCCM.open(
            key: key,
            nonce: aeadNonce(packetId: packetId, fromNode: fromNode),
            ciphertextAndTag: ciphertext,
            aad: aeadAAD(fromNode: fromNode, toNode: toNode),
            tagLength: aeadTagLength
        )
    }

    /// Returns ciphertext ‖ 12-byte tag.
    static func encryptAEAD(key: Data, packetId: UInt32, fromNode: UInt32, toNode: UInt32, plaintext: Data) -> Data? {
        AESCCM.seal(
            key: key,
            nonce: aeadNonce(packetId: packetId, fromNode: fromNode),
            plaintext: plaintext,
            aad: aeadAAD(fromNode: fromNode, toNode: toNode),
            tagLength: aeadTagLength
        )
    }

    /// Encrypts with the scheme the channel uses (CCM for AEAD channels, CTR otherwise).
    static func encrypt(_ plaintext: Data, for channel: KnownChannel, packetId: UInt32, fromNode: UInt32, toNode: UInt32) -> Data? {
        channel.useAead
            ? encryptAEAD(key: channel.key, packetId: packetId, fromNode: fromNode, toNode: toNode, plaintext: plaintext)
            : encryptCTR(key: channel.key, packetId: packetId, fromNode: fromNode, plaintext: plaintext)
    }

    // MARK: - Packet decryption

    /// Decrypts a channel-encrypted packet with the first channel whose hash matches
    /// `channelHash` (authoritative for live packets, as on Windows; no brute force).
    /// CTR has no integrity check, so the plaintext must parse as `Meshtastic_Data`
    /// with a known portnum; CCM additionally verifies its tag.
    static func tryDecrypt(
        ciphertext: Data,
        channelHash: UInt32,
        packetId: UInt32,
        from: UInt32,
        to: UInt32,
        channels: [KnownChannel]
    ) -> (data: Meshtastic_Data, channelIndex: Int)? {
        guard !ciphertext.isEmpty, channelHash <= UInt32(UInt8.max) else { return nil }
        for channel in channels where UInt32(channel.hash) == channelHash {
            let plaintext = channel.useAead
                ? decryptAEAD(key: channel.key, packetId: packetId, fromNode: from, toNode: to, ciphertext: ciphertext)
                : decryptCTR(key: channel.key, packetId: packetId, fromNode: from, ciphertext: ciphertext)
            guard let plaintext,
                  let data = try? Meshtastic_Data(serializedBytes: plaintext),
                  data.portnum != .unknownApp else { continue }
            return (data, channel.index)
        }
        return nil
    }
}
