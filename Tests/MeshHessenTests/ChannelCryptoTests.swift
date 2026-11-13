import Foundation
import Testing

@testable import MeshHessen

@Suite("ChannelCrypto")
struct ChannelCryptoTests {
    // Values ported from the Windows client's ChannelDecryptTests.cs / ProtobufV28FeatureTests.cs.
    private let testPsk = Data([
        0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ])
    private let testChannelName = "TestCh"
    private let fromNode: UInt32 = 0x9e9f3118
    private let packetId: UInt32 = 0xEA01136D
    private let key32 = Data((1...32).map { UInt8($0) })
    private let plain = Data("Moin Meshhessen! 73".utf8)

    // MARK: - Key expansion

    @Test("Empty PSK and alias 0 mean no encryption")
    func noEncryption() {
        #expect(ChannelCrypto.expandKey(Data()) == nil)
        #expect(ChannelCrypto.expandKey(Data([0])) == nil)
    }

    @Test("Alias 1 is the default key; alias n bumps its last byte by n - 1")
    func aliasExpansion() throws {
        #expect(ChannelCrypto.expandKey(Data([1])) == ChannelCrypto.defaultKey)
        let alias5 = try #require(ChannelCrypto.expandKey(Data([5])))
        #expect(alias5.count == 16)
        #expect(alias5.prefix(15) == ChannelCrypto.defaultKey.prefix(15))
        #expect(alias5[15] == ChannelCrypto.defaultKey[15] &+ 4)
    }

    @Test("16- and 32-byte keys are used as-is; other lengths are rejected")
    func fullKeys() {
        #expect(ChannelCrypto.expandKey(testPsk) == testPsk)
        #expect(ChannelCrypto.expandKey(key32) == key32)
        #expect(ChannelCrypto.expandKey(Data(count: 7)) == nil)
    }

    // MARK: - Names and hashes

    @Test("Unnamed channels hash under the preset display name")
    func effectiveNames() {
        #expect(ChannelCrypto.effectiveName(settingsName: "Mesh Hessen", usePreset: true, modemPreset: .longFast) == "Mesh Hessen")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: true, modemPreset: .longFast) == "LongFast")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: true, modemPreset: .longModerate) == "LongMod")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: true, modemPreset: .shortTurbo) == "ShortTurbo")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: true, modemPreset: .mediumFast) == "MediumFast")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: false, modemPreset: .longFast) == "Custom")
        #expect(ChannelCrypto.effectiveName(settingsName: "", usePreset: true, modemPreset: nil) == "LongFast")
    }

    @Test("Channel hash of the default LongFast channel is 8")
    func defaultChannelHash() {
        #expect(ChannelCrypto.hash(name: "LongFast", key: ChannelCrypto.defaultKey) == 0x08)
    }

    @Test("Channel hash of the Windows test channel is 0x1C")
    func windowsTestChannelHash() {
        #expect(ChannelCrypto.hash(name: testChannelName, key: testPsk) == 0x1C)
    }

    @Test("Known channels skip unencrypted and disabled slots and resolve preset names")
    func knownChannelList() {
        var primary = Meshtastic_Channel()
        primary.index = 0
        primary.role = .primary
        primary.settings.psk = Data([1])
        var plainChannel = Meshtastic_Channel()
        plainChannel.index = 1
        plainChannel.role = .secondary
        var disabled = Meshtastic_Channel()
        disabled.index = 2
        disabled.role = .disabled
        disabled.settings.psk = testPsk
        var aead = Meshtastic_Channel()
        aead.index = 3
        aead.role = .secondary
        aead.settings.name = testChannelName
        aead.settings.psk = testPsk
        aead.settings.useAead = true
        var lora = Meshtastic_Config.LoRaConfig()
        lora.usePreset = true
        lora.modemPreset = .mediumFast

        let known = ChannelCrypto.knownChannels(from: [aead, disabled, plainChannel, primary], loraConfig: lora)
        #expect(known.map(\.index) == [0, 3])
        #expect(known[0].name == "MediumFast")
        #expect(known[0].key == ChannelCrypto.defaultKey)
        #expect(known[0].useAead == false)
        #expect(known[1].name == testChannelName)
        #expect(known[1].useAead)
    }

    // MARK: - AES-CTR

    @Test("AES-128-CTR matches NIST SP 800-38A F.5.1")
    func nistCtr128() {
        let output = AESCTR.crypt(
            key: hex("2b7e151628aed2a6abf7158809cf4f3c"),
            nonce: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
            ciphertext: hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        )
        #expect(output == hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"))
    }

    @Test("AES-256-CTR matches NIST SP 800-38A F.5.5")
    func nistCtr256() {
        let output = AESCTR.crypt(
            key: hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
            nonce: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
            ciphertext: hex("6bc1bee22e409f96e93d7e117393172a")
        )
        #expect(output == hex("601ec313775789a5b7a7f504bbf3d228"))
    }

    @Test("CTR nonce is [packetId u64 LE][fromNode u32 LE][0 × 4]")
    func ctrNonceLayout() {
        let nonce = ChannelCrypto.ctrNonce(packetId: packetId, fromNode: fromNode)
        #expect(nonce == hex("6d1301ea00000000" + "18319f9e" + "00000000"))
        #expect(ChannelCrypto.aeadNonce(packetId: packetId, fromNode: fromNode) == hex("6d1301ea0000000018319f9e00"))
        #expect(ChannelCrypto.aeadAAD(fromNode: fromNode, toNode: 0xFFFFFFFF) == hex("18319f9effffffff"))
    }

    @Test("CTR round trip with 16- and 32-byte keys; odd lengths keep their size")
    func ctrRoundTrip() throws {
        for key in [testPsk, key32] {
            let cipher = try #require(ChannelCrypto.encryptCTR(key: key, packetId: packetId, fromNode: fromNode, plaintext: plain))
            #expect(cipher.count == plain.count)
            #expect(cipher != plain)
            #expect(ChannelCrypto.decryptCTR(key: key, packetId: packetId, fromNode: fromNode, ciphertext: cipher) == plain)
        }
    }

    // MARK: - AEAD

    @Test("AEAD round trip restores the plaintext and appends a 12-byte tag")
    func aeadRoundTrip() throws {
        let cipher = try #require(ChannelCrypto.encryptAEAD(
            key: key32, packetId: 0xABCDEF, fromNode: 0x11223344, toNode: 0x55667788, plaintext: plain
        ))
        #expect(cipher.count == plain.count + 12)
        let back = ChannelCrypto.decryptAEAD(
            key: key32, packetId: 0xABCDEF, fromNode: 0x11223344, toNode: 0x55667788, ciphertext: cipher
        )
        #expect(back == plain)
    }

    @Test("AEAD round trip works with an AES-128 key")
    func aeadRoundTrip128() throws {
        let key16 = Data(key32.prefix(16))
        let cipher = try #require(ChannelCrypto.encryptAEAD(key: key16, packetId: 3, fromNode: 1, toNode: 2, plaintext: plain))
        #expect(ChannelCrypto.decryptAEAD(key: key16, packetId: 3, fromNode: 1, toNode: 2, ciphertext: cipher) == plain)
    }

    @Test("AEAD detects tampering and a wrong context")
    func aeadTamper() throws {
        let cipher = try #require(ChannelCrypto.encryptAEAD(
            key: key32, packetId: 0xABCDEF, fromNode: 0x11223344, toNode: 0x55667788, plaintext: plain
        ))
        var flipped = cipher
        flipped[3] ^= 0x01
        #expect(ChannelCrypto.decryptAEAD(key: key32, packetId: 0xABCDEF, fromNode: 0x11223344, toNode: 0x55667788, ciphertext: flipped) == nil)
        #expect(ChannelCrypto.decryptAEAD(key: key32, packetId: 0xABCDEF, fromNode: 0x11223344, toNode: 0x99999999, ciphertext: cipher) == nil)
        #expect(ChannelCrypto.decryptAEAD(key: key32, packetId: 0xABCDEF, fromNode: 0x99999999, toNode: 0x55667788, ciphertext: cipher) == nil)
        #expect(ChannelCrypto.decryptAEAD(key: key32, packetId: 0xABCDEE, fromNode: 0x11223344, toNode: 0x55667788, ciphertext: cipher) == nil)
        #expect(ChannelCrypto.decryptAEAD(key: key32, packetId: 3, fromNode: 1, toNode: 2, ciphertext: Data(count: 12)) == nil)
    }

    // MARK: - tryDecrypt

    @Test("A CTR packet is decrypted with the channel whose hash matches")
    func tryDecryptCtr() throws {
        let channels = [
            ChannelCrypto.KnownChannel(index: 0, name: "LongFast", key: ChannelCrypto.defaultKey, useAead: false),
            ChannelCrypto.KnownChannel(index: 1, name: testChannelName, key: testPsk, useAead: false),
        ]
        let cipher = try encryptedText("hallo welt", key: testPsk, aead: false, to: 0xFFFFFFFF)

        let result = try #require(ChannelCrypto.tryDecrypt(
            ciphertext: cipher, channelHash: 0x1C, packetId: packetId, from: fromNode, to: 0xFFFFFFFF, channels: channels
        ))
        #expect(result.channelIndex == 1)
        #expect(result.data.portnum == .textMessageApp)
        #expect(String(decoding: result.data.payload, as: UTF8.self) == "hallo welt")
    }

    @Test("An AEAD packet is decrypted and authenticated")
    func tryDecryptAead() throws {
        let channels = [ChannelCrypto.KnownChannel(index: 2, name: testChannelName, key: testPsk, useAead: true)]
        let cipher = try encryptedText("authentisch", key: testPsk, aead: true, to: 0x12345678)

        let result = try #require(ChannelCrypto.tryDecrypt(
            ciphertext: cipher, channelHash: 0x1C, packetId: packetId, from: fromNode, to: 0x12345678, channels: channels
        ))
        #expect(result.channelIndex == 2)
        #expect(String(decoding: result.data.payload, as: UTF8.self) == "authentisch")

        // Wrong destination → AAD mismatch → rejected.
        #expect(ChannelCrypto.tryDecrypt(
            ciphertext: cipher, channelHash: 0x1C, packetId: packetId, from: fromNode, to: 0xFFFFFFFF, channels: channels
        ) == nil)
    }

    @Test("No matching hash or a wrong key leaves the packet undecrypted")
    func tryDecryptNoMatch() throws {
        let channels = [ChannelCrypto.KnownChannel(index: 0, name: testChannelName, key: testPsk, useAead: false)]
        let cipher = try encryptedText("secret", key: key32, aead: false, to: 0xFFFFFFFF)

        #expect(ChannelCrypto.tryDecrypt(
            ciphertext: cipher, channelHash: 200, packetId: packetId, from: fromNode, to: 0xFFFFFFFF, channels: channels
        ) == nil)
        #expect(ChannelCrypto.tryDecrypt(
            ciphertext: cipher, channelHash: 0x1C, packetId: packetId, from: fromNode, to: 0xFFFFFFFF, channels: channels
        ) == nil)
        #expect(ChannelCrypto.tryDecrypt(
            ciphertext: Data(), channelHash: 0x1C, packetId: packetId, from: fromNode, to: 0xFFFFFFFF, channels: channels
        ) == nil)
    }

    // MARK: - Helpers

    private func encryptedText(_ text: String, key: Data, aead: Bool, to: UInt32) throws -> Data {
        var data = Meshtastic_Data()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)
        let plaintext = try data.serializedData()
        let channel = ChannelCrypto.KnownChannel(index: 0, name: testChannelName, key: key, useAead: aead)
        return try #require(ChannelCrypto.encrypt(plaintext, for: channel, packetId: packetId, fromNode: fromNode, toNode: to))
    }
}

@Suite("ChannelCrypto protocol integration")
@MainActor
struct ChannelCryptoProtocolTests {
    private let testPsk = Data([
        0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ])
    private let senderID: UInt32 = 0x9e9f3118

    @Test("A channel-encrypted packet with a matching hash is decrypted and dispatched")
    func liveDecrypt() throws {
        let (service, state, directory) = makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = NodeInfo(id: senderID, nodeId: "!9e9f3118", shortName: "S", longName: "Sender")
        state.upsertNode(node)
        try ingestChannel(index: 1, role: .secondary, name: "TestCh", psk: testPsk, through: service)

        try ingestEncryptedStatus("Entschlüsselt", channelHash: 0x1C, key: testPsk, packetID: 0x1001, through: service)

        #expect(node.status == "Entschlüsselt")
        #expect(state.allMessages.isEmpty)
    }

    @Test("An unnamed default channel is matched under its preset name")
    func liveDecryptPresetName() throws {
        let (service, state, directory) = makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = NodeInfo(id: senderID, nodeId: "!9e9f3118", shortName: "S", longName: "Sender")
        state.upsertNode(node)
        var config = Meshtastic_Config()
        config.lora.usePreset = true
        config.lora.modemPreset = .mediumFast
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.config = config
        service.onVirtualFromRadioPayload(try fromRadio.serializedData())
        try ingestChannel(index: 0, role: .primary, name: "", psk: Data([1]), through: service)

        let hash = ChannelCrypto.hash(name: "MediumFast", key: ChannelCrypto.defaultKey)
        try ingestEncryptedStatus(
            "Voreinstellung", channelHash: UInt32(hash), key: ChannelCrypto.defaultKey, packetID: 0x1002, through: service
        )

        #expect(node.status == "Voreinstellung")
    }

    @Test("A packet on an unknown channel still becomes an encrypted placeholder")
    func unknownChannelPlaceholder() throws {
        let (service, state, directory) = makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = NodeInfo(id: senderID, nodeId: "!9e9f3118", shortName: "S", longName: "Sender")
        state.upsertNode(node)
        try ingestChannel(index: 1, role: .secondary, name: "TestCh", psk: testPsk, through: service)

        try ingestEncryptedStatus("Geheim", channelHash: 200, key: testPsk, packetID: 0x1003, through: service)

        #expect(node.status.isEmpty)
        #expect(state.allMessages.count == 1)
        #expect(state.allMessages.first?.isEncrypted == true)
    }

    @Test("The RF-only traceroute is encrypted for the primary channel with OK_TO_MQTT cleared")
    func rfOnlyTraceroute() throws {
        let primary = ChannelCrypto.KnownChannel(index: 0, name: "TestCh", key: testPsk, useAead: false)
        var data = Meshtastic_Data()
        data.portnum = .tracerouteApp
        data.payload = try Meshtastic_RouteDiscovery().serializedData()
        data.wantResponse = true

        let packet = try #require(MeshtasticProtocolService.rfOnlyTraceroutePacket(
            data: data, from: 0x11111111, to: 0x22222222, packetId: 0x3333, primaryChannel: primary
        ))
        #expect(packet.channel == 0x1C)
        #expect(packet.from == 0x11111111)
        #expect(packet.to == 0x22222222)
        #expect(packet.id == 0x3333)
        #expect(packet.hopLimit == 7)
        #expect(packet.hopStart == 7)
        #expect(!packet.wantAck)

        guard case .encrypted(let ciphertext) = packet.payloadVariant else {
            Issue.record("RF-only traceroute must be pre-encrypted")
            return
        }
        let plaintext = try #require(ChannelCrypto.decryptCTR(key: testPsk, packetId: 0x3333, fromNode: 0x11111111, ciphertext: ciphertext))
        let decoded = try Meshtastic_Data(serializedBytes: plaintext)
        #expect(decoded.portnum == .tracerouteApp)
        #expect(decoded.wantResponse)
        #expect(decoded.bitfield == 2)
    }

    @Test("The RF-only traceroute uses CCM on AEAD primaries and refuses channel hash 0")
    func rfOnlyTracerouteAeadAndHashZero() throws {
        var data = Meshtastic_Data()
        data.portnum = .tracerouteApp
        data.wantResponse = true

        let aead = ChannelCrypto.KnownChannel(index: 0, name: "TestCh", key: testPsk, useAead: true)
        let packet = try #require(MeshtasticProtocolService.rfOnlyTraceroutePacket(
            data: data, from: 1, to: 2, packetId: 3, primaryChannel: aead
        ))
        guard case .encrypted(let ciphertext) = packet.payloadVariant else {
            Issue.record("RF-only traceroute must be pre-encrypted")
            return
        }
        let plaintext = try #require(ChannelCrypto.decryptAEAD(key: testPsk, packetId: 3, fromNode: 1, toNode: 2, ciphertext: ciphertext))
        #expect(try Meshtastic_Data(serializedBytes: plaintext).bitfield == 2)

        // "AA" XOR an all-zero key hashes to 0, which the firmware would treat as a channel index.
        let zeroHash = ChannelCrypto.KnownChannel(index: 0, name: "AA", key: Data(count: 16), useAead: false)
        #expect(zeroHash.hash == 0)
        #expect(MeshtasticProtocolService.rfOnlyTraceroutePacket(
            data: data, from: 1, to: 2, packetId: 3, primaryChannel: zeroHash
        ) == nil)
    }

    // MARK: - Helpers

    private func makeHarness() -> (service: MeshtasticProtocolService, state: AppState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-ChannelCryptoTests-\(UUID().uuidString)", isDirectory: true)
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0
        )
        let service = MeshtasticProtocolService(telemetryDatabase: database)
        let state = AppState()
        service.appState = state
        return (service, state, directory)
    }

    private func ingestChannel(
        index: Int32,
        role: Meshtastic_Channel.Role,
        name: String,
        psk: Data,
        through service: MeshtasticProtocolService
    ) throws {
        var channel = Meshtastic_Channel()
        channel.index = index
        channel.role = role
        channel.settings.name = name
        channel.settings.psk = psk
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.channel = channel
        service.onVirtualFromRadioPayload(try fromRadio.serializedData())
    }

    private func ingestEncryptedStatus(
        _ status: String,
        channelHash: UInt32,
        key: Data,
        packetID: UInt32,
        through service: MeshtasticProtocolService
    ) throws {
        var message = Meshtastic_StatusMessage()
        message.status = status
        var data = Meshtastic_Data()
        data.portnum = .nodeStatusApp
        data.payload = try message.serializedData()
        let ciphertext = try #require(ChannelCrypto.encryptCTR(
            key: key, packetId: packetID, fromNode: senderID, plaintext: try data.serializedData()
        ))
        var packet = Meshtastic_MeshPacket()
        packet.from = senderID
        packet.to = UInt32.max
        packet.id = packetID
        packet.channel = channelHash
        packet.viaMqtt = true
        packet.encrypted = ciphertext
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.packet = packet
        service.onVirtualFromRadioPayload(try fromRadio.serializedData())
    }
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
