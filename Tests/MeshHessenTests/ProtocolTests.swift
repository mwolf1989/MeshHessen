import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

@Suite("Traceroute Payload Decoding")
struct TraceroutePayloadDecodingTests {

    @Test("Packed routes preserve signed SNR values")
    func packedRouteAndSignedSnr() throws {
        var message = Meshtastic_RouteDiscovery()
        message.route = [0x01020304, 0xAABBCCDD]
        message.snrTowards = [-40, 12]

        let decoded = try MeshtasticProtocolService.decodeRouteDiscovery(message.serializedData())

        #expect(decoded.route == message.route)
        #expect(decoded.snrTowards == [-40, 12])
    }

    @Test("Missing SNR data decodes as an empty list")
    func missingSnr() throws {
        var message = Meshtastic_RouteDiscovery()
        message.route = [0x01020304]

        let decoded = try MeshtasticProtocolService.decodeRouteDiscovery(message.serializedData())

        #expect(decoded.route == message.route)
        #expect(decoded.snrTowards.isEmpty)
    }

    @Test("Truncated packed payload throws instead of trapping")
    func truncatedPayload() {
        let truncatedPackedFixed32 = Data([0x0A, 0x04, 0x01])

        do {
            _ = try MeshtasticProtocolService.decodeRouteDiscovery(truncatedPackedFixed32)
            Issue.record("Expected the truncated traceroute payload to fail decoding")
        } catch {
            // Expected: SwiftProtobuf rejects the malformed payload safely.
        }
    }
}

@Suite("Emoji Reaction Protocol")
struct EmojiReactionProtocolTests {
    @Test("Standard reaction marker decodes emoji from UTF-8 payload")
    func standardPayload() {
        var data = Meshtastic_Data()
        data.emoji = 1
        data.payload = Data("❤️".utf8)

        #expect(MeshtasticProtocolService.decodeEmojiReaction(data) == "❤️")
    }

    @Test("Outgoing reactions use marker value one and preserve multi-scalar emoji")
    func outgoingPayload() {
        let data = MeshtasticProtocolService.makeEmojiReactionData(emoji: "👨‍👩‍👧‍👦", replyID: 42)

        #expect(data.emoji == 1)
        #expect(data.replyID == 42)
        #expect(String(data: data.payload, encoding: .utf8) == "👨‍👩‍👧‍👦")
    }

    @Test("Legacy scalar reactions remain readable")
    func legacyScalar() {
        var data = Meshtastic_Data()
        data.emoji = 0x1F44D

        #expect(MeshtasticProtocolService.decodeEmojiReaction(data) == "👍")
    }

    @Test("Empty or malformed reaction payload has a visible fallback")
    func visibleFallback() {
        var data = Meshtastic_Data()
        data.emoji = 1
        data.payload = Data([0xFF])

        #expect(MeshtasticProtocolService.decodeEmojiReaction(data) == "👍")
    }
}

@Suite("Text Reply Protocol")
struct TextReplyProtocolTests {
    @Test("Ordinary replies preserve their target without becoming reactions")
    func outgoingReplyPayload() {
        let data = MeshtasticProtocolService.makeTextMessageData(
            text: "Das ist die Antwort",
            replyToPacketId: 0x12345678
        )

        #expect(data.portnum == .textMessageApp)
        #expect(String(data: data.payload, encoding: .utf8) == "Das ist die Antwort")
        #expect(data.replyID == 0x12345678)
        #expect(data.emoji == 0)
    }

    @Test("Plain text messages do not contain reply metadata")
    func ordinaryTextPayload() {
        let data = MeshtasticProtocolService.makeTextMessageData(text: "Ohne Antwortbezug")

        #expect(data.replyID == 0)
        #expect(data.emoji == 0)
    }

    @Test("Zero is not emitted as a reply target")
    func zeroReplyTarget() {
        let data = MeshtasticProtocolService.makeTextMessageData(
            text: "Ohne Antwortbezug",
            replyToPacketId: 0
        )

        #expect(data.replyID == 0)
    }
}

@Suite("Device Configuration Safety")
struct DeviceConfigurationSafetyTests {
    private func emptySnapshot() -> MeshtasticProtocolService.DeviceConfigSnapshot {
        MeshtasticProtocolService.DeviceConfigSnapshot(
            device: .init(),
            position: .init(),
            lora: .init(),
            bluetooth: .init(),
            network: .init(),
            display: .init(),
            power: .init(),
            mqtt: .init()
        )
    }

    @Test("only changed configuration categories are selected for writing")
    func onlyChangedCategories() {
        let original = emptySnapshot()
        var changed = original
        changed.lora.hopLimit = 7

        #expect(
            MeshtasticProtocolService.changedDeviceConfigCategories(changed, replacing: original)
                == ["LoRa"]
        )
    }

    @Test("unchanged complete configuration requires no writes")
    func unchangedConfiguration() {
        let snapshot = emptySnapshot()

        #expect(
            MeshtasticProtocolService.changedDeviceConfigCategories(snapshot, replacing: snapshot)
                .isEmpty
        )
    }

    @Test("verification compares only categories changed by the user")
    func verificationScope() {
        let expected = emptySnapshot()
        var actual = expected
        actual.lora.hopLimit = 3
        actual.network.wifiEnabled = true

        #expect(
            MeshtasticProtocolService.mismatchedDeviceConfigCategories(
                actual: actual,
                expected: expected,
                categories: ["LoRa"]
            ) == ["LoRa"]
        )
    }
}
