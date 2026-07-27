import CoreData
import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

@Suite("Unknown Telemetry Senders")
@MainActor
struct UnknownTelemetrySenderProtocolTests {
    private func makeHarness() -> (
        service: MeshtasticProtocolService,
        state: AppState,
        database: TelemetryDatabaseService,
        persistence: PersistenceController,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MeshHessen-UnknownTelemetryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0
        )
        let persistence = PersistenceController(
            managedObjectModel: TestModelFactory.makeModel(),
            inMemory: true
        )
        let service = MeshtasticProtocolService(telemetryDatabase: database)
        let state = AppState()
        service.appState = state
        service.coreDataStore = MeshCoreDataStore(persistenceController: persistence)
        return (service, state, database, persistence, directory)
    }

    @Test("Environment telemetry creates and persists an unknown sender")
    func environmentTelemetry() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let senderID: UInt32 = 0xDEADBEEF

        var environment = Meshtastic_EnvironmentMetrics()
        environment.temperature = 21.5
        environment.relativeHumidity = 63
        var telemetry = Meshtastic_Telemetry()
        telemetry.environmentMetrics = environment
        var data = Meshtastic_Data()
        data.portnum = .telemetryApp
        data.payload = try telemetry.serializedData()

        try ingest(data: data, senderID: senderID, packetID: 101, through: harness.service)
        harness.database.waitForPendingWrites()

        let node = try #require(harness.state.node(forId: senderID))
        #expect(node.name == "!deadbeef")
        #expect(node.temperature == 21.5)
        #expect(node.relativeHumidity == 63)
        #expect(
            harness.database.getTimeSeries(
                nodeIds: [senderID],
                metric: .temperature,
                days: 0
            ).map(\.value) == [21.5]
        )
        #expect(harness.database.rowCount(in: "packet_rx") == 1)
        #expect(harness.database.rowCount(in: "environment_telemetry") == 1)

        try await Task.sleep(for: .milliseconds(250))
        let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
        request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(senderID))
        #expect(try harness.persistence.container.viewContext.count(for: request) == 1)
    }

    @Test("PAX telemetry creates an unknown sender and retains its counters")
    func paxTelemetry() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let senderID: UInt32 = 0x00ABCDEF
        var data = Meshtastic_Data()
        data.portnum = .paxcounterApp
        data.payload = Data([
            0x08, 0x03, // wifi = 3
            0x10, 0x04, // ble = 4
            0x18, 0x78, // uptime = 120
        ])

        try ingest(data: data, senderID: senderID, packetID: 102, through: harness.service)
        harness.database.waitForPendingWrites()

        let node = try #require(harness.state.node(forId: senderID))
        #expect(node.name == "!00abcdef")
        #expect(node.paxMetrics == NodePaxMetrics(wifi: 3, ble: 4, uptimeSeconds: 120))
        #expect(
            harness.database.getTimeSeries(
                nodeIds: [senderID],
                metric: .paxWifiCount,
                days: 0
            ).map(\.value) == [3]
        )
        #expect(harness.database.rowCount(in: "pax_telemetry") == 1)
    }

    private func ingest(
        data: Meshtastic_Data,
        senderID: UInt32,
        packetID: UInt32,
        through service: MeshtasticProtocolService
    ) throws {
        var packet = Meshtastic_MeshPacket()
        packet.from = senderID
        packet.to = UInt32.max
        packet.id = packetID
        packet.decoded = data

        var fromRadio = Meshtastic_FromRadio()
        fromRadio.packet = packet
        service.onVirtualFromRadioPayload(try fromRadio.serializedData())
    }
}
