import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

@Suite("Meshtastic Stream Framing")
struct MeshtasticStreamFrameCodecTests {
    @Test("Fragmented and adjacent frames decode after noisy bytes")
    func fragmentedFrames() throws {
        let first = Data([1, 2, 3])
        let second = Data([4, 5])
        let firstFrame = try MeshtasticStreamFrameCodec.frame(first)
        let secondFrame = try MeshtasticStreamFrameCodec.frame(second)

        var decoder = MeshtasticStreamFrameDecoder()
        let prefix = Data([0x41, 0x42]) + firstFrame.prefix(3)
        #expect(decoder.append(prefix).isEmpty)
        #expect(decoder.bufferedByteCount == 3)

        let suffix = firstFrame.dropFirst(3) + secondFrame
        #expect(decoder.append(Data(suffix)) == [first, second])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A split magic header is retained")
    func splitMagicHeader() throws {
        let payload = Data([0x08, 0x01])
        let frame = try MeshtasticStreamFrameCodec.frame(payload)
        var decoder = MeshtasticStreamFrameDecoder()

        #expect(decoder.append(Data([0x00, 0x94])).isEmpty)
        #expect(decoder.bufferedByteCount == 1)
        #expect(decoder.append(Data(frame.dropFirst())) == [payload])
    }

    @Test("Invalid lengths are skipped without losing the next frame")
    func invalidLengthRecovery() throws {
        let validPayload = Data([0x08, 0x2A])
        let validFrame = try MeshtasticStreamFrameCodec.frame(validPayload)
        let invalidFrame = Data([0x94, 0xC3, 0x02, 0x01])
        var decoder = MeshtasticStreamFrameDecoder()

        #expect(decoder.append(invalidFrame + validFrame) == [validPayload])
    }

    @Test("ADMIN_APP is detected only in decoded mesh packets")
    func adminCommandFilter() throws {
        var adminData = Meshtastic_Data()
        adminData.portnum = .adminApp
        var adminPacket = Meshtastic_MeshPacket()
        adminPacket.decoded = adminData
        var adminToRadio = Meshtastic_ToRadio()
        adminToRadio.packet = adminPacket
        let adminPayload = try adminToRadio.serializedData()

        #expect(
            MeshtasticStreamFrameCodec.containsAdminCommand(adminPayload)
        )

        var textData = Meshtastic_Data()
        textData.portnum = .textMessageApp
        var textPacket = Meshtastic_MeshPacket()
        textPacket.decoded = textData
        var textToRadio = Meshtastic_ToRadio()
        textToRadio.packet = textPacket
        let textPayload = try textToRadio.serializedData()
        #expect(!MeshtasticStreamFrameCodec.containsAdminCommand(textPayload))

        var encryptedPacket = Meshtastic_MeshPacket()
        encryptedPacket.encrypted = Data([1, 2, 3])
        var encryptedToRadio = Meshtastic_ToRadio()
        encryptedToRadio.packet = encryptedPacket
        let encryptedPayload = try encryptedToRadio.serializedData()
        #expect(!MeshtasticStreamFrameCodec.containsAdminCommand(encryptedPayload))
    }
}

@Suite("Virtual Node Replay")
struct VirtualNodeReplayCacheTests {
    @Test("Replay is deterministic and echoes the requesting client's nonce")
    func deterministicReplay() throws {
        var cache = VirtualNodeReplayCache()

        var myInfo = Meshtastic_MyNodeInfo()
        myInfo.myNodeNum = 0x01020304
        var myInfoEnvelope = Meshtastic_FromRadio()
        myInfoEnvelope.myInfo = myInfo
        #expect(try ingest(myInfoEnvelope, into: &cache))

        var highChannel = Meshtastic_Channel()
        highChannel.index = 3
        var highChannelEnvelope = Meshtastic_FromRadio()
        highChannelEnvelope.channel = highChannel
        #expect(try ingest(highChannelEnvelope, into: &cache))

        var lowChannel = Meshtastic_Channel()
        lowChannel.index = 0
        var lowChannelEnvelope = Meshtastic_FromRadio()
        lowChannelEnvelope.channel = lowChannel
        #expect(try ingest(lowChannelEnvelope, into: &cache))

        var config = Meshtastic_Config()
        config.device = Meshtastic_Config.DeviceConfig()
        var configEnvelope = Meshtastic_FromRadio()
        configEnvelope.config = config
        #expect(try ingest(configEnvelope, into: &cache))

        var moduleConfig = Meshtastic_ModuleConfig()
        moduleConfig.mqtt = Meshtastic_ModuleConfig.MQTTConfig()
        var moduleConfigEnvelope = Meshtastic_FromRadio()
        moduleConfigEnvelope.moduleConfig = moduleConfig
        #expect(try ingest(moduleConfigEnvelope, into: &cache))

        for nodeNumber: UInt32 in [99, 4] {
            var node = Meshtastic_NodeInfo()
            node.num = nodeNumber
            var envelope = Meshtastic_FromRadio()
            envelope.nodeInfo = node
            #expect(try ingest(envelope, into: &cache))
        }

        var physicalCompletion = Meshtastic_FromRadio()
        physicalCompletion.configCompleteID = 7
        #expect(try !ingest(physicalCompletion, into: &cache))
        #expect(cache.snapshot.isReady)
        #expect(cache.snapshot.channelCount == 2)
        #expect(cache.snapshot.nodeCount == 2)

        let replay = try cache.replayFrames(wantConfigID: 0xAABBCCDD)
        let envelopes = try replay.map {
            try Meshtastic_FromRadio(
                serializedBytes: MeshtasticStreamFrameCodec.payload(from: $0)
            )
        }

        #expect(envelopes.count == 8)
        #expect(envelopes[0].myInfo.myNodeNum == 0x01020304)
        #expect(envelopes[1].channel.index == 0)
        #expect(envelopes[2].channel.index == 3)
        #expect(envelopes[5].nodeInfo.num == 4)
        #expect(envelopes[6].nodeInfo.num == 99)
        #expect(envelopes[7].configCompleteID == 0xAABBCCDD)
    }

    @Test("New frames replace the same replay category")
    func replayReplacement() throws {
        var cache = VirtualNodeReplayCache()
        for value: UInt32 in [1, 2] {
            var node = Meshtastic_NodeInfo()
            node.num = 42
            node.lastHeard = value
            var envelope = Meshtastic_FromRadio()
            envelope.nodeInfo = node
            #expect(try ingest(envelope, into: &cache))
        }

        #expect(cache.snapshot.nodeCount == 1)
        let replay = try cache.replayFrames(wantConfigID: 3)
        let nodeEnvelope = try Meshtastic_FromRadio(
            serializedBytes: MeshtasticStreamFrameCodec.payload(from: replay[0])
        )
        #expect(nodeEnvelope.nodeInfo.lastHeard == 2)
    }

    private func ingest(
        _ envelope: Meshtastic_FromRadio,
        into cache: inout VirtualNodeReplayCache
    ) throws -> Bool {
        let payload = try envelope.serializedData()
        return cache.ingest(
            fromRadioPayload: payload,
            framedData: try MeshtasticStreamFrameCodec.frame(payload)
        )
    }
}

@Suite("Drop-oldest forwarding queue")
struct BoundedDropOldestQueueTests {
    @Test("The newest one hundred frames are retained")
    func dropsOldest() {
        var queue = BoundedDropOldestQueue<Int>(capacity: 100)
        var dropped: [Int] = []
        for value in 0..<105 {
            if let value = queue.enqueue(value) {
                dropped.append(value)
            }
        }

        #expect(dropped == [0, 1, 2, 3, 4])
        #expect(queue.count == 100)
        #expect(queue.dequeue() == 5)
        #expect(queue.elements.last == 104)
    }
}
