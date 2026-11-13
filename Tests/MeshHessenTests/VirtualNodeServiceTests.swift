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

    @Test("Mesh Beacon module config is cached and replayed")
    func meshBeaconReplay() throws {
        var cache = VirtualNodeReplayCache()
        var moduleConfig = Meshtastic_ModuleConfig()
        var beacon = Meshtastic_ModuleConfig.MeshBeaconConfig()
        beacon.broadcastMessage = "Hallo Hessen"
        moduleConfig.meshBeacon = beacon
        var envelope = Meshtastic_FromRadio()
        envelope.moduleConfig = moduleConfig
        #expect(try ingest(envelope, into: &cache))

        let replay = try replayEnvelopes(cache, wantConfigID: 5)
        #expect(replay.contains { $0.moduleConfig.meshBeacon.broadcastMessage == "Hallo Hessen" })
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

    @Test("Stage 1 nonce replays configuration without node infos")
    func configOnlyStage() throws {
        let cache = try populatedCache()
        let envelopes = try replayEnvelopes(
            cache,
            wantConfigID: VirtualNodeReplayCache.configOnlyNonce
        )

        #expect(VirtualNodeReplayCache.configOnlyNonce == 69420)
        #expect(envelopes.count == 7)
        #expect(envelopes.filter(isMyInfo).count == 1)
        #expect(envelopes[0].myInfo.myNodeNum == ownNodeNumber)
        #expect(envelopes[1].metadata.firmwareVersion == "2.7.0")
        #expect(envelopes.filter { if case .config? = $0.payloadVariant { true } else { false } }.count == 1)
        #expect(envelopes.filter { if case .moduleConfig? = $0.payloadVariant { true } else { false } }.count == 1)
        #expect(envelopes.filter { if case .channel? = $0.payloadVariant { true } else { false } }.count == 2)
        #expect(envelopes.filter(isNodeInfo).isEmpty)
        #expect(envelopes.last?.configCompleteID == 69420)
    }

    @Test("Stage 2 nonce replays node infos only")
    func nodesOnlyStage() throws {
        let cache = try populatedCache()
        let envelopes = try replayEnvelopes(
            cache,
            wantConfigID: VirtualNodeReplayCache.nodesOnlyNonce
        )

        #expect(VirtualNodeReplayCache.nodesOnlyNonce == 69421)
        #expect(envelopes.count == 3)
        #expect(envelopes.dropLast().allSatisfy(isNodeInfo))
        #expect(envelopes.dropLast().map(\.nodeInfo.num) == [4, 99])
        #expect(envelopes.allSatisfy { !isMyInfo($0) })
        #expect(envelopes.last?.configCompleteID == 69421)
    }

    @Test("Other nonces still receive the full dump")
    func genericNonceFullDump() throws {
        let cache = try populatedCache()
        let envelopes = try replayEnvelopes(cache, wantConfigID: 12345)

        // my_info, metadata, 2 channels, 1 config, 1 module config, 2 nodes, completion.
        #expect(envelopes.count == 9)
        #expect(envelopes[0].myInfo.myNodeNum == ownNodeNumber)
        #expect(envelopes[6].nodeInfo.num == 4)
        #expect(envelopes[7].nodeInfo.num == 99)
        #expect(envelopes.last?.configCompleteID == 12345)
    }

    @Test("A missing own node is synthesised once from the fallback")
    func ownNodeFallback() throws {
        var fallback = Meshtastic_NodeInfo()
        fallback.num = ownNodeNumber
        fallback.user.id = String(format: "!%08x", ownNodeNumber)
        fallback.user.longName = "Mac Node"
        fallback.user.shortName = "MAC"

        let missingOwn = try populatedCache()
        for nonce in [VirtualNodeReplayCache.nodesOnlyNonce, 12345] {
            let envelopes = try replayEnvelopes(missingOwn, wantConfigID: nonce, ownNodeFallback: fallback)
            let ownNodes = envelopes.filter { isNodeInfo($0) && $0.nodeInfo.num == ownNodeNumber }
            #expect(ownNodes.count == 1)
            #expect(ownNodes.first?.nodeInfo.user.id == "!01020304")
            #expect(ownNodes.first?.nodeInfo.user.longName == "Mac Node")
            #expect(envelopes.filter(isNodeInfo).count == 3)
        }

        let stageOne = try replayEnvelopes(
            missingOwn,
            wantConfigID: VirtualNodeReplayCache.configOnlyNonce,
            ownNodeFallback: fallback
        )
        #expect(stageOne.filter(isNodeInfo).isEmpty)

        var withOwn = missingOwn
        var ownNode = Meshtastic_NodeInfo()
        ownNode.num = ownNodeNumber
        ownNode.user.longName = "Radio Node"
        var ownEnvelope = Meshtastic_FromRadio()
        ownEnvelope.nodeInfo = ownNode
        #expect(try ingest(ownEnvelope, into: &withOwn))

        let envelopes = try replayEnvelopes(
            withOwn,
            wantConfigID: VirtualNodeReplayCache.nodesOnlyNonce,
            ownNodeFallback: fallback
        )
        let ownNodes = envelopes.filter { isNodeInfo($0) && $0.nodeInfo.num == ownNodeNumber }
        #expect(ownNodes.count == 1)
        #expect(ownNodes.first?.nodeInfo.user.longName == "Radio Node")
        #expect(envelopes.filter(isNodeInfo).count == 3)
    }

    private let ownNodeNumber: UInt32 = 0x01020304

    /// my_info, metadata, two channels, one config, one module config and two
    /// foreign nodes (4 and 99); the own node has no NodeInfo frame.
    private func populatedCache() throws -> VirtualNodeReplayCache {
        var cache = VirtualNodeReplayCache()

        var myInfo = Meshtastic_MyNodeInfo()
        myInfo.myNodeNum = ownNodeNumber
        var myInfoEnvelope = Meshtastic_FromRadio()
        myInfoEnvelope.myInfo = myInfo
        #expect(try ingest(myInfoEnvelope, into: &cache))

        var metadata = Meshtastic_DeviceMetadata()
        metadata.firmwareVersion = "2.7.0"
        var metadataEnvelope = Meshtastic_FromRadio()
        metadataEnvelope.metadata = metadata
        #expect(try ingest(metadataEnvelope, into: &cache))

        for index: Int32 in [3, 0] {
            var channel = Meshtastic_Channel()
            channel.index = index
            var envelope = Meshtastic_FromRadio()
            envelope.channel = channel
            #expect(try ingest(envelope, into: &cache))
        }

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
        return cache
    }

    private func isMyInfo(_ envelope: Meshtastic_FromRadio) -> Bool {
        if case .myInfo? = envelope.payloadVariant { return true }
        return false
    }

    private func isNodeInfo(_ envelope: Meshtastic_FromRadio) -> Bool {
        if case .nodeInfo? = envelope.payloadVariant { return true }
        return false
    }

    private func replayEnvelopes(
        _ cache: VirtualNodeReplayCache,
        wantConfigID: UInt32,
        ownNodeFallback: Meshtastic_NodeInfo? = nil
    ) throws -> [Meshtastic_FromRadio] {
        try cache.replayFrames(wantConfigID: wantConfigID, ownNodeFallback: ownNodeFallback).map {
            try Meshtastic_FromRadio(serializedBytes: MeshtasticStreamFrameCodec.payload(from: $0))
        }
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
