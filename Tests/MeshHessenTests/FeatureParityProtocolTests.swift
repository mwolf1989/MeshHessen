import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

@Suite("Direct RF Classification")
struct DirectRFClassificationTests {
    @Test("Hop count is derived from hop start and remaining limit")
    func hopCount() {
        #expect(MeshtasticProtocolService.hopCount(hopStart: 7, hopLimit: 7) == 0)
        #expect(MeshtasticProtocolService.hopCount(hopStart: 7, hopLimit: 4) == 3)
        #expect(MeshtasticProtocolService.hopCount(hopStart: 0, hopLimit: 0) == 0)
        #expect(MeshtasticProtocolService.hopCount(hopStart: 2, hopLimit: 7) == 0)
    }

    @Test("MQTT traffic is never classified as a direct RF contact")
    func mqttIsNotDirect() {
        #expect(MeshtasticProtocolService.isDirectRF(hopCount: 0, viaMqtt: false))
        #expect(!MeshtasticProtocolService.isDirectRF(hopCount: 0, viaMqtt: true))
        #expect(!MeshtasticProtocolService.isDirectRF(hopCount: 1, viaMqtt: false))
    }
}

@Suite("Remote Node Information Requests")
struct RemoteNodeInformationRequestTests {
    private let destination: UInt32 = 0xAABBCCDD

    @Test("User information request targets the node-info port")
    func userInfo() throws {
        let data = try MeshtasticProtocolService.makeNodeInfoRequestData(
            .userInfo,
            destinationId: destination,
            timestamp: 1_700_000_000
        )

        #expect(data.portnum == .nodeinfoApp)
        #expect(data.wantResponse)
        #expect(data.dest == destination)
        #expect(data.payload.isEmpty)
    }

    @Test("Position request carries the current time")
    func position() throws {
        let timestamp: UInt32 = 1_700_000_000
        let data = try MeshtasticProtocolService.makeNodeInfoRequestData(
            .position,
            destinationId: destination,
            timestamp: timestamp
        )
        let position = try Meshtastic_Position(serializedBytes: data.payload)

        #expect(data.portnum == .positionApp)
        #expect(position.time == timestamp)
    }

    @Test(
        "Every telemetry request selects its matching oneof",
        arguments: [
            NodeInfoRequestType.deviceMetrics,
            .environmentMetrics,
            .airQualityMetrics,
            .powerMetrics,
            .localStats,
            .hostMetrics,
        ]
    )
    func telemetry(type: NodeInfoRequestType) throws {
        let data = try MeshtasticProtocolService.makeNodeInfoRequestData(
            type,
            destinationId: destination,
            timestamp: 1_700_000_000
        )
        let telemetry = try Meshtastic_Telemetry(serializedBytes: data.payload)

        #expect(data.portnum == .telemetryApp)
        switch (type, telemetry.variant) {
        case (.deviceMetrics, .deviceMetrics),
             (.environmentMetrics, .environmentMetrics),
             (.airQualityMetrics, .airQualityMetrics),
             (.powerMetrics, .powerMetrics),
             (.localStats, .localStats),
             (.hostMetrics, .hostMetrics):
            break
        default:
            Issue.record("Unexpected telemetry oneof for \(type)")
        }
    }

    @Test("PAX request uses the dedicated port with an empty protobuf")
    func pax() throws {
        let data = try MeshtasticProtocolService.makeNodeInfoRequestData(
            .paxCounter,
            destinationId: destination,
            timestamp: 1_700_000_000
        )

        #expect(data.portnum == .paxcounterApp)
        #expect(data.payload.isEmpty)
    }
}

@Suite("Node List Parity")
@MainActor
struct NodeListParityTests {
    @Test("Own, favorite, and pinned nodes receive stable priority")
    func prioritySorting() {
        let ordinary = NodeInfo(id: 1, nodeId: "!00000001", shortName: "O", longName: "Ordinary")
        let pinned = NodeInfo(id: 2, nodeId: "!00000002", shortName: "P", longName: "Pinned")
        let favorite = NodeInfo(id: 3, nodeId: "!00000003", shortName: "F", longName: "Favorite")
        let own = NodeInfo(id: 4, nodeId: "!00000004", shortName: "M", longName: "Mine")
        pinned.isPinned = true
        favorite.isFavorite = true
        own.isOwnNode = true

        #expect(NodeSortOrder.name.sorted([ordinary, pinned, favorite, own]).map(\.id) == [4, 3, 2, 1])
    }

    @Test("Age filter excludes nodes without a timestamp")
    func ageFilter() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(NodeAgeFilter.fiveMinutes.includes(lastHeard: 9_800, now: now))
        #expect(!NodeAgeFilter.fiveMinutes.includes(lastHeard: 9_000, now: now))
        #expect(!NodeAgeFilter.fiveMinutes.includes(lastHeard: 0, now: now))
        #expect(NodeAgeFilter.all.includes(lastHeard: 0, now: now))
    }

    @Test("Delivery updates stay inside their conversation context")
    func scopedDeliveryState() {
        let state = AppState()
        let first = MessageItem(
            packetId: 42,
            time: "12:00",
            from: "Me",
            fromId: 1,
            toId: 0xFFFFFFFF,
            message: "First",
            channelIndex: 0,
            channelName: "Primary",
            deliveryState: .pending
        )
        let second = MessageItem(
            packetId: 42,
            time: "12:01",
            from: "Me",
            fromId: 1,
            toId: 0xFFFFFFFF,
            message: "Second",
            channelIndex: 1,
            channelName: "Secondary",
            deliveryState: .pending
        )
        state.appendMessage(first)
        state.appendMessage(second)

        state.updateDeliveryState(requestId: 42, state: .acknowledged, context: .channel(1))

        #expect(state.channelMessages[0]?.first?.deliveryState == .pending)
        #expect(state.channelMessages[1]?.first?.deliveryState == .acknowledged)
    }
}
