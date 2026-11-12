import Foundation
import Testing

@testable import MeshHessen

@Suite("Telemetry Data Correctness")
struct TelemetryDataCorrectnessTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let myNodeId: UInt32 = 0x1234_5678

    // MARK: - Signal samples

    @Test("a direct RF packet records both SNR and RSSI")
    func directPacketRecordsSignal() {
        let samples = TelemetryDatabaseService.signalSamples(snr: 5.5, rssi: -90, hopCount: 0, viaMqtt: false)
        #expect(samples == [.snr: 5.5, .rssi: -90])
    }

    @Test("a relayed packet records no signal samples")
    func relayedPacketRecordsNothing() {
        let samples = TelemetryDatabaseService.signalSamples(snr: 5.5, rssi: -90, hopCount: 2, viaMqtt: false)
        #expect(samples.isEmpty)
    }

    @Test("an MQTT packet records no signal samples")
    func mqttPacketRecordsNothing() {
        let samples = TelemetryDatabaseService.signalSamples(snr: 5.5, rssi: -90, hopCount: 0, viaMqtt: true)
        #expect(samples.isEmpty)
    }

    @Test("an SNR of 0 is treated as not measured")
    func zeroSnrIsSkipped() {
        let samples = TelemetryDatabaseService.signalSamples(snr: 0, rssi: -90, hopCount: 0, viaMqtt: false)
        #expect(samples == [.rssi: -90])
    }

    @Test("a relayed packet is still counted but adds no SNR series point")
    func relayedPacketStillCounted() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-DataCorrectness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0,
            clock: { Self.now }
        )
        let nodeId: UInt32 = 7

        database.insertPacketRx(
            nodeId: nodeId,
            packetId: 1,
            timestamp: Self.now.addingTimeInterval(-120),
            snr: 4,
            rssi: -90,
            hopCount: 1,
            wantAck: false
        )
        database.insertPacketRx(
            nodeId: nodeId,
            packetId: 2,
            timestamp: Self.now.addingTimeInterval(-60),
            snr: 6,
            rssi: -80,
            hopCount: 0,
            wantAck: false
        )
        database.waitForPendingWrites()

        let snrPoints = database.getTimeSeries(nodeIds: [nodeId], metric: .snr, days: 1)
        #expect(snrPoints.map(\.value) == [6])
        let packetCount = database.getTimeSeries(nodeIds: [nodeId], metric: .packetCount, days: 1)
        #expect(packetCount.first?.value == 2)
    }

    // MARK: - Request detection

    private func data(wantResponse: Bool, requestID: UInt32) -> Meshtastic_Data {
        var data = Meshtastic_Data()
        data.wantResponse = wantResponse
        data.requestID = requestID
        return data
    }

    @Test("a want-response packet to us without request id is a request")
    func requestToMe() {
        let request = data(wantResponse: true, requestID: 0)
        #expect(MeshtasticProtocolService.isIncomingRequest(request, to: Self.myNodeId, myNodeId: Self.myNodeId))
    }

    @Test("a packet carrying a request id is a response")
    func responseIsNotRequest() {
        let response = data(wantResponse: true, requestID: 7)
        #expect(!MeshtasticProtocolService.isIncomingRequest(response, to: Self.myNodeId, myNodeId: Self.myNodeId))
    }

    @Test("a request addressed to another node is not ours")
    func requestToOtherNode() {
        let request = data(wantResponse: true, requestID: 0)
        #expect(!MeshtasticProtocolService.isIncomingRequest(request, to: 0x9999, myNodeId: Self.myNodeId))
    }

    @Test("without a known own node id nothing counts as a request")
    func unknownOwnNode() {
        let request = data(wantResponse: true, requestID: 0)
        #expect(!MeshtasticProtocolService.isIncomingRequest(request, to: 0, myNodeId: 0))
    }

    // MARK: - Traceroute SNR

    @Test("traceroute SNR 0 and -128 mean no RF measurement")
    func tracerouteSnrSentinels() {
        #expect(TracerouteHop.decodedSNR(0) == nil)
        #expect(TracerouteHop.decodedSNR(-128) == nil)
        #expect(TracerouteHop.decodedSNR(20) == 5.0)
        #expect(TracerouteHop.decodedSNR(-6) == -1.5)
    }

    // MARK: - Display range

    @Test("explicit display range exists only when the user set both bounds")
    func explicitDisplayRange() {
        let automatic = TelemetryDashboardWidget(metric: .rssi)
        #expect(automatic.explicitDisplayRange == nil)
        #expect(automatic.effectiveDisplayRange == TelemetrySeriesMetric.rssi.suggestedRange)

        let configured = TelemetryDashboardWidget(metric: .rssi, displayMinimum: -120, displayMaximum: -40)
        #expect(configured.explicitDisplayRange == -120...(-40))
    }
}
