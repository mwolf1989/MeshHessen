import Foundation
import Testing

@testable import MeshHessen

@Suite("Node Status")
@MainActor
struct NodeStatusTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Database

    @Test("An upserted status is read back")
    func upsertThenRead() async {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.upsertNodeStatus(nodeId: 0x1001, status: "Unterwegs", timestamp: Self.now)
        database.upsertNodeStatus(nodeId: 0x1001, status: "Akku schwach", timestamp: Self.now)
        database.waitForPendingWrites()

        let statuses = await database.nodeStatuses()
        #expect(statuses == [0x1001: "Akku schwach"])
    }

    @Test("An empty status removes the stored row")
    func emptyStatusRemoves() async {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.upsertNodeStatus(nodeId: 0x1002, status: "Unterwegs", timestamp: Self.now)
        database.upsertNodeStatus(nodeId: 0x1002, status: "", timestamp: Self.now)
        database.waitForPendingWrites()

        #expect(await database.nodeStatuses().isEmpty)
    }

    @Test("Statuses older than maxAgeDays are not returned")
    func oldStatusesExcluded() async {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.upsertNodeStatus(nodeId: 0x1003, status: "Alt", timestamp: Self.now.addingTimeInterval(-8 * 86_400))
        database.upsertNodeStatus(nodeId: 0x1004, status: "Neu", timestamp: Self.now.addingTimeInterval(-86_400))
        database.waitForPendingWrites()

        #expect(await database.nodeStatuses(maxAgeDays: 7) == [0x1004: "Neu"])
        #expect(await database.nodeStatuses(maxAgeDays: 10).count == 2)
    }

    // MARK: - Parsing

    @Test("The status payload is decoded and trimmed")
    func parsesAndTrims() throws {
        var message = Meshtastic_StatusMessage()
        message.status = " Unterwegs "
        let payload = try message.serializedData()

        #expect(MeshtasticProtocolService.nodeStatusText(from: payload) == "Unterwegs")
    }

    @Test("Garbage bytes are rejected")
    func garbageIsNil() {
        let payload = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(MeshtasticProtocolService.nodeStatusText(from: payload) == nil)
    }

    @Test("The status text is clamped to 79 UTF-8 bytes")
    func clampsToByteLimit() {
        let clamped = UTF8Limits.clamp(String(repeating: "ä", count: 50), maxBytes: 79)
        #expect(clamped.count == 39)
        #expect(clamped.utf8.count == 78)
        #expect(MeshtasticProtocolService.nodeStatusMaxBytes == 79)
    }

    // MARK: - Protocol

    @Test("A received status updates the node, persists, and an empty one clears it")
    func receivedStatusUpdatesNode() async throws {
        let (service, state, database, directory) = makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.upsertNode(NodeInfo(id: 0x2001, nodeId: "!00002001", shortName: "N", longName: "Node"))

        try ingestStatus("Unterwegs", from: 0x2001, packetID: 1, through: service)
        #expect(state.node(forId: 0x2001)?.status == "Unterwegs")
        database.waitForPendingWrites()
        #expect(await database.nodeStatuses()[0x2001] == "Unterwegs")

        try ingestStatus("", from: 0x2001, packetID: 2, through: service)
        #expect(state.node(forId: 0x2001)?.status == "")
        database.waitForPendingWrites()
        #expect(await database.nodeStatuses()[0x2001] == nil)
    }

    @Test("Stored statuses are backfilled only into nodes without a live status")
    func backfillFillsEmptyStatuses() async {
        let (service, state, database, directory) = makeHarness()
        defer { try? FileManager.default.removeItem(at: directory) }
        let quiet = NodeInfo(id: 0x3001, nodeId: "!00003001", shortName: "Q", longName: "Quiet")
        let live = NodeInfo(id: 0x3002, nodeId: "!00003002", shortName: "L", longName: "Live")
        live.status = "Live"
        state.upsertNode(quiet)
        state.upsertNode(live)

        let now = Date()
        database.upsertNodeStatus(nodeId: 0x3001, status: "Gespeichert", timestamp: now)
        database.upsertNodeStatus(nodeId: 0x3002, status: "Veraltet", timestamp: now)
        database.upsertNodeStatus(nodeId: 0x3003, status: "Unbekannt", timestamp: now)
        database.waitForPendingWrites()

        let restored = await service.backfillStoredNodeStatuses()
        #expect(restored == 1)
        #expect(quiet.status == "Gespeichert")
        #expect(live.status == "Live")
    }

    // MARK: - Helpers

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-NodeStatusTests-\(UUID().uuidString)", isDirectory: true)
        return (
            TelemetryDatabaseService(
                databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
                retentionDays: 0,
                clock: { Self.now }
            ),
            directory
        )
    }

    private func makeHarness() -> (
        service: MeshtasticProtocolService,
        state: AppState,
        database: TelemetryDatabaseService,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-NodeStatusProtocolTests-\(UUID().uuidString)", isDirectory: true)
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0
        )
        let service = MeshtasticProtocolService(telemetryDatabase: database)
        let state = AppState()
        service.appState = state
        return (service, state, database, directory)
    }

    private func ingestStatus(
        _ status: String,
        from senderID: UInt32,
        packetID: UInt32,
        through service: MeshtasticProtocolService
    ) throws {
        var message = Meshtastic_StatusMessage()
        message.status = status
        var data = Meshtastic_Data()
        data.portnum = .nodeStatusApp
        data.payload = try message.serializedData()
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
