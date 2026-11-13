import Foundation
import Testing

@testable import MeshHessen

// Airtime estimation for the Funk-Echo reply-airtime tile (ported from the Windows
// client's LoRaAirtimeTests.cs).

@Suite("LoRaAirtime")
struct LoRaAirtimeTests {
    @Test func presetTableMatchesFirmwareValues() {
        #expect(LoRaAirtime.parameters(for: .longFast).map { [$0.sf, Int($0.bwKHz), $0.cr] } == [11, 250, 5])
        #expect(LoRaAirtime.parameters(for: .longSlow).map { [$0.sf, Int($0.bwKHz), $0.cr] } == [12, 125, 8])
        #expect(LoRaAirtime.parameters(for: .shortSlow).map { [$0.sf, Int($0.bwKHz), $0.cr] } == [8, 250, 5])
        #expect(LoRaAirtime.parameters(for: .shortFast).map { [$0.sf, Int($0.bwKHz), $0.cr] } == [7, 250, 5])
        #expect(LoRaAirtime.parameters(for: .narrowFast)?.bwKHz == 62.5)
        #expect(LoRaAirtime.parameters(for: .tinySlow).map { [$0.sf, $0.cr] } == [8, 6])
    }

    @Test func unknownPresetsReturnNil() {
        #expect(LoRaAirtime.parameters(for: .veryLongSlow) == nil)
        #expect(LoRaAirtime.parameters(for: .UNRECOGNIZED(99)) == nil)
        #expect(LoRaAirtime.replyAirtimeMs(
            type: .nodeInfo, detail: nil, hops: 0, expected: "yes", preset: .veryLongSlow
        ) == nil)
        #expect(LoRaAirtime.totalReplyAirtimeMs(records: [], preset: .veryLongSlow) == nil)
    }

    @Test func airtimeGrowsWithPayloadAndSpreadingFactor() {
        let small = LoRaAirtime.airtimeMs(payloadBytes: 32, sf: 11, bwKHz: 250, cr: 5)
        let big = LoRaAirtime.airtimeMs(payloadBytes: 96, sf: 11, bwKHz: 250, cr: 5)
        #expect(big > small)

        let sf7 = LoRaAirtime.airtimeMs(payloadBytes: 64, sf: 7, bwKHz: 250, cr: 5)
        let sf11 = LoRaAirtime.airtimeMs(payloadBytes: 64, sf: 11, bwKHz: 250, cr: 5)
        #expect(sf11 > sf7 * 5)
    }

    @Test func longFast64BytesLandsInPlausibleRange() {
        let ms = LoRaAirtime.airtimeMs(payloadBytes: 64, sf: 11, bwKHz: 250, cr: 5)
        #expect((300...800).contains(ms))
    }

    @Test func exactSemtechValueForLongFast() {
        // tSym = 8.192 ms; preamble 20.25 sym; payload = 8 + ceil((512 - 44 + 44) / 44) * 5 = 68 sym
        let ms = LoRaAirtime.airtimeMs(payloadBytes: 64, sf: 11, bwKHz: 250, cr: 5)
        #expect(abs(ms - (20.25 + 68) * 8.192) < 0.001)
    }

    @Test func lowDataRateOptimisationKicksInAbove16msSymbols() {
        // SF12 / 125 kHz → 32.8 ms symbols → DE = 1.
        let withOptimisation = LoRaAirtime.airtimeMs(payloadBytes: 64, sf: 12, bwKHz: 125, cr: 5)
        #expect((1_500...5_000).contains(withOptimisation))
    }

    @Test func replyAirtimeCountsOnlyCertainReplies() {
        #expect(LoRaAirtime.replyAirtimeMs(type: .nodeInfo, detail: nil, hops: 0, expected: "yes", preset: .longFast) != nil)
        #expect(LoRaAirtime.replyAirtimeMs(type: .position, detail: nil, hops: 0, expected: "prec:13", preset: .longFast) != nil)
        #expect(LoRaAirtime.replyAirtimeMs(type: .position, detail: nil, hops: 0, expected: "no-pos", preset: .longFast) == nil)
        #expect(LoRaAirtime.replyAirtimeMs(type: .telemetry, detail: "Environment", hops: 0, expected: "sensor", preset: .longFast) == nil)
        #expect(LoRaAirtime.replyAirtimeMs(type: .admin, detail: nil, hops: 0, expected: "auth", preset: .longFast) == nil)
        #expect(LoRaAirtime.replyAirtimeMs(type: .nodeInfo, detail: nil, hops: 0, expected: nil, preset: .longFast) == nil)
    }

    @Test func tracerouteReplyGrowsWithRouteLength() throws {
        let direct = try #require(LoRaAirtime.replyAirtimeMs(
            type: .traceroute, detail: nil, hops: 0, expected: "yes", preset: .longFast
        ))
        let relayed = try #require(LoRaAirtime.replyAirtimeMs(
            type: .traceroute, detail: nil, hops: 3, expected: "yes", preset: .longFast
        ))
        #expect(relayed > direct)
    }

    @Test func replyPayloadSizes() {
        #expect(LoRaAirtime.replyPayloadBytes(type: .nodeInfo, detail: nil, hops: nil) == 66)
        #expect(LoRaAirtime.replyPayloadBytes(type: .position, detail: nil, hops: nil) == 46)
        #expect(LoRaAirtime.replyPayloadBytes(type: .telemetry, detail: "Device", hops: nil) == 48)
        #expect(LoRaAirtime.replyPayloadBytes(type: .telemetry, detail: "LocalStats", hops: nil) == 61)
        #expect(LoRaAirtime.replyPayloadBytes(type: .traceroute, detail: nil, hops: nil) == 34)
        #expect(LoRaAirtime.replyPayloadBytes(type: .traceroute, detail: nil, hops: 2) == 46)
    }

    @Test func totalMultipliesByCountAndSkipsUncertainRows() throws {
        func record(_ type: RequestEchoType, count: Int, expected: String?, route: String? = nil) -> RequestEchoRecord {
            RequestEchoRecord(
                id: 1, nodeId: 1, typeRaw: type.rawValue, firstSeen: Date(), lastSeen: Date(),
                count: count, hops: 1, viaMqtt: false, route: route, detail: nil, expected: expected
            )
        }
        let one = try #require(LoRaAirtime.replyAirtimeMs(
            type: .nodeInfo, detail: nil, hops: 0, expected: "yes", preset: .longFast
        ))
        let trace = try #require(LoRaAirtime.replyAirtimeMs(
            type: .traceroute, detail: nil, hops: 2, expected: "yes", preset: .longFast
        ))
        let total = try #require(LoRaAirtime.totalReplyAirtimeMs(
            records: [
                record(.nodeInfo, count: 3, expected: "yes"),
                record(.admin, count: 5, expected: "auth"),
                record(.traceroute, count: 1, expected: "yes", route: "!00000001,!00000002"),
            ],
            preset: .longFast
        ))
        #expect(abs(total - (3 * one + trace)) < 0.001)
    }

    @Test func formatting() {
        #expect(LoRaAirtime.formatted(ms: 640.4) == "≈ 640 ms")
        #expect(LoRaAirtime.formatted(ms: 1_234) == "≈ 1.2 s")
    }
}

// Funk-Echo radar geometry and the request path shown on the map (plan 018).

@Suite("RequestEchoRadar")
@MainActor
struct RequestEchoRadarTests {
    private func record(
        node: UInt32,
        type: RequestEchoType,
        count: Int,
        route: String? = nil
    ) -> RequestEchoRecord {
        RequestEchoRecord(
            id: Int64(node), nodeId: node, typeRaw: type.rawValue, firstSeen: Date(), lastSeen: Date(),
            count: count, hops: 1, viaMqtt: false, route: route, detail: nil, expected: "yes"
        )
    }

    @Test func stationsAggregatePerNodeBusiestFirst() {
        let stations = RequestEchoRadarGeometry.stations(from: [
            record(node: 1, type: .nodeInfo, count: 2),
            record(node: 2, type: .position, count: 7),
            record(node: 1, type: .traceroute, count: 3),
        ])
        #expect(stations.map(\.nodeId) == [2, 1])
        #expect(stations[1].total == 5)
        #expect(stations[1].perType == ["nodeInfo": 2, "traceroute": 3])
    }

    @Test func stationsAreCappedAt24() {
        let records = (1...30).map { record(node: UInt32($0), type: .nodeInfo, count: $0) }
        let stations = RequestEchoRadarGeometry.stations(from: records)
        #expect(stations.count == 24)
        #expect(stations.first?.nodeId == 30)
    }

    @Test func fractionIsLogScaled() {
        #expect(RequestEchoRadarGeometry.fraction(total: 10, maxTotal: 10) == 1)
        #expect(abs(RequestEchoRadarGeometry.fraction(total: 1, maxTotal: 3) - 0.5) < 1e-9)
        #expect(RequestEchoRadarGeometry.fraction(total: 0, maxTotal: 0) == 0)
    }

    @Test func angleMatchesWindowsHash() {
        // C#: (nodeId * 2654435761u % 3600u) / 3600.0 * 2π with 32-bit wrap-around.
        let nodeId: UInt32 = 0x1234_5678
        let expected = Double((nodeId &* 2_654_435_761) % 3_600) / 3_600 * 2 * .pi
        #expect(RequestEchoRadarGeometry.angle(nodeId: nodeId) == expected)
        #expect(RequestEchoRadarGeometry.angle(nodeId: 1) == Double(2_654_435_761 % 3_600) / 3_600 * 2 * .pi)
    }

    @Test func busierStationsSitCloserAndBigger() {
        let near = RequestEchoRadarGeometry.radius(fraction: 1, maxRadius: 100)
        let far = RequestEchoRadarGeometry.radius(fraction: 0, maxRadius: 100)
        #expect(near < far)
        #expect(abs(far - 92) < 1e-9)
        #expect(RequestEchoRadarGeometry.dotRadius(fraction: 1) == 11)
        #expect(RequestEchoRadarGeometry.glowRadius(fraction: 0) == 10)
        #expect(RequestEchoRadarGeometry.maxRadius(for: CGSize(width: 70, height: 300)) == nil)
        #expect(RequestEchoRadarGeometry.maxRadius(for: CGSize(width: 300, height: 200)) == 66)
    }

    @Test func requestRouteIsReversedWithRequesterAppended() throws {
        let requester = NodeInfo(id: 0xC, nodeId: "!0000000c", shortName: "REQ", longName: "Requester")
        requester.latitude = 50.1
        requester.longitude = 8.6
        let relay = NodeInfo(id: 0xA, nodeId: "!0000000a", shortName: "A", longName: "Relay A")
        let nodes: [UInt32: NodeInfo] = [0xC: requester, 0xA: relay]
        // The request travelled C → A → B → us; the stored route lists A, B.
        let result = try #require(RequestEchoRoute.tracerouteResult(
            for: record(node: 0xC, type: .traceroute, count: 1, route: "!0000000a,!0000000b"),
            myNodeId: 0x1,
            ownLatitude: 50.0,
            ownLongitude: 8.5,
            node: { nodes[$0] }
        ))
        #expect(result.hops.map(\.nodeId) == [0xB, 0xA, 0xC])
        #expect(result.hops.allSatisfy { $0.snr == nil })
        #expect(result.hops.map(\.nodeName) == ["!0000000b", "Relay A", "Requester"])
        #expect(result.hops.last?.latitude == 50.1)
        #expect(result.sourceNodeId == 0x1)
        #expect(result.sourceLatitude == 50.0)
        #expect(result.targetNodeId == 0xC)
        #expect(result.targetName == "Requester")
    }

    @Test func requestRouteNeedsRouteAndKnownRequester() {
        let requester = NodeInfo(id: 0xC, nodeId: "!0000000c", shortName: "REQ", longName: "Requester")
        #expect(RequestEchoRoute.tracerouteResult(
            for: record(node: 0xC, type: .traceroute, count: 1, route: nil),
            myNodeId: 1, ownLatitude: nil, ownLongitude: nil, node: { $0 == 0xC ? requester : nil }
        ) == nil)
        #expect(RequestEchoRoute.tracerouteResult(
            for: record(node: 0xC, type: .traceroute, count: 1, route: "!0000000a"),
            myNodeId: 1, ownLatitude: nil, ownLongitude: nil, node: { _ in nil }
        ) == nil)
        #expect(RequestEchoRoute.tracerouteResult(
            for: record(node: 0xC, type: .position, count: 1, route: "!0000000a"),
            myNodeId: 1, ownLatitude: nil, ownLongitude: nil, node: { $0 == 0xC ? requester : nil }
        ) == nil)
    }
}
