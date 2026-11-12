import CoreData
import Foundation
import Testing

@testable import MeshHessen

@Suite("Node Position Retention")
@MainActor
struct NodePositionRetentionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - AppState merge

    @Test("A position-less upsert keeps the known position")
    func positionlessUpsertKeepsPosition() throws {
        let state = AppState()
        let known = makeNode(id: 0x1001)
        known.latitude = 50.11
        known.longitude = 8.68
        known.altitude = 120
        state.upsertNode(known)

        state.upsertNode(makeNode(id: 0x1001, longName: "Renamed"))

        let node = try #require(state.node(forId: 0x1001))
        #expect(node.latitude == 50.11)
        #expect(node.longitude == 8.68)
        #expect(node.altitude == 120)
        #expect(node.longName == "Renamed")
    }

    @Test("viaMqtt only changes through NodeDB snapshots; lastHeard never moves backwards")
    func viaMqttAndLastHeard() throws {
        let state = AppState()
        let known = makeNode(id: 0x1002)
        known.viaMqtt = true
        known.lastHeard = 2_000
        known.lastSeen = "later"
        state.upsertNode(known)

        let older = makeNode(id: 0x1002)
        older.viaMqtt = false
        older.lastHeard = 1_000
        older.lastSeen = "earlier"
        state.upsertNode(older)

        let node = try #require(state.node(forId: 0x1002))
        #expect(node.viaMqtt)
        #expect(node.lastHeard == 2_000)
        #expect(node.lastSeen == "later")

        let snapshot = makeNode(id: 0x1002)
        snapshot.viaMqtt = false
        snapshot.lastHeard = 3_000
        snapshot.lastSeen = "newest"
        state.upsertNode(snapshot, refreshNodeDatabaseFlags: true)

        #expect(node.viaMqtt == false)
        #expect(node.lastHeard == 3_000)
        #expect(node.lastSeen == "newest")
    }

    @Test("0/0 coordinates do not overwrite a real position")
    func zeroCoordinatesIgnored() throws {
        let state = AppState()
        let known = makeNode(id: 0x1003)
        known.latitude = 50.5
        known.longitude = 9.1
        state.upsertNode(known)

        let noFix = makeNode(id: 0x1003)
        noFix.latitude = 0
        noFix.longitude = 0
        noFix.altitude = 0
        state.upsertNode(noFix)

        let node = try #require(state.node(forId: 0x1003))
        #expect(node.latitude == 50.5)
        #expect(node.longitude == 9.1)

        let fresh = makeNode(id: 0x1004)
        fresh.latitude = 0
        fresh.longitude = 0
        state.upsertNode(fresh)
        #expect(state.node(forId: 0x1004)?.latitude == nil)
        #expect(state.node(forId: 0x1004)?.longitude == nil)
    }

    @Test("Hardware model, role and public key are refreshed only by non-empty values")
    func deviceMetadataMerge() throws {
        let state = AppState()
        state.upsertNode(makeNode(id: 0x1005))

        let update = makeNode(id: 0x1005)
        update.hardwareModel = "heltecV3"
        update.role = "router"
        update.isInfrastructure = true
        update.publicKey = Data(repeating: 0xAB, count: 32)
        state.upsertNode(update)

        let empty = makeNode(id: 0x1005)
        empty.hardwareModel = "Unknown"
        state.upsertNode(empty)

        let node = try #require(state.node(forId: 0x1005))
        #expect(node.hardwareModel == "heltecV3")
        #expect(node.role == "router")
        #expect(node.isInfrastructure)
        #expect(node.publicKey == Data(repeating: 0xAB, count: 32))
    }

    // MARK: - Protocol handlers

    @Test("A NodeInfo broadcast does not erase the persisted position")
    func nodeInfoBroadcastKeepsStoredPosition() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let nodeID: UInt32 = 0x2001

        let known = makeNode(id: nodeID)
        known.latitude = 50.2
        known.longitude = 8.9
        harness.state.upsertNode(known)

        try ingest(portnum: .nodeinfoApp, payload: user(longName: "Broadcast").serializedData(),
                   from: nodeID, packetID: 1, through: harness.service)

        #expect(harness.state.node(forId: nodeID)?.latitude == 50.2)
        let stored = try await storedLatitude(nodeID: nodeID, in: harness.persistence)
        #expect(stored == 50.2)
    }

    @Test("A position received before the NodeInfo is applied once the node is known")
    func pendingPositionApplied() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let nodeID: UInt32 = 0x2002

        try ingest(portnum: .positionApp, payload: position(lat: 50.3, lon: 8.4, alt: 210).serializedData(),
                   from: nodeID, packetID: 2, through: harness.service)
        #expect(harness.state.node(forId: nodeID) == nil)

        try ingest(portnum: .nodeinfoApp, payload: user(longName: "Late").serializedData(),
                   from: nodeID, packetID: 3, through: harness.service)

        let node = try #require(harness.state.node(forId: nodeID))
        #expect(abs((node.latitude ?? 0) - 50.3) < 1e-6)
        #expect(abs((node.longitude ?? 0) - 8.4) < 1e-6)
        #expect(node.altitude == 210)
    }

    @Test("Valid positions are recorded in node_positions for known and unknown nodes")
    func positionsAreRecorded() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.state.upsertNode(makeNode(id: 0x2003))
        try ingest(portnum: .positionApp, payload: position(lat: 50.1, lon: 8.1, alt: 1).serializedData(),
                   from: 0x2003, packetID: 4, through: harness.service)
        try ingest(portnum: .positionApp, payload: position(lat: 50.2, lon: 8.2, alt: 2).serializedData(),
                   from: 0x2004, packetID: 5, through: harness.service)
        try ingest(portnum: .positionApp, payload: position(lat: 0, lon: 0, alt: 0).serializedData(),
                   from: 0x2005, packetID: 6, through: harness.service)
        harness.database.waitForPendingWrites()

        #expect(harness.database.rowCount(in: "node_positions") == 2)
    }

    @Test("Backfill restores stored positions without overwriting existing ones")
    func backfillRestoresMissingPositions() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        harness.database.insertNodePosition(
            nodeId: 0x3001, latitude: 50.6, longitude: 8.6, altitude: 300,
            groundSpeed: 0, groundTrack: 0, timestamp: Date()
        )
        harness.database.insertNodePosition(
            nodeId: 0x3002, latitude: 49.0, longitude: 7.0, altitude: nil,
            groundSpeed: 0, groundTrack: 0, timestamp: Date()
        )
        harness.state.upsertNode(makeNode(id: 0x3001))
        let positioned = makeNode(id: 0x3002)
        positioned.latitude = 51.0
        positioned.longitude = 9.0
        harness.state.upsertNode(positioned)

        let restored = await harness.service.backfillStoredPositions()

        #expect(restored == 1)
        #expect(harness.state.node(forId: 0x3001)?.latitude == 50.6)
        #expect(harness.state.node(forId: 0x3001)?.altitude == 300)
        #expect(harness.state.node(forId: 0x3002)?.latitude == 51.0)
    }

    // MARK: - Telemetry database

    @Test("latestNodePositions returns the newest position per node")
    func latestPositionWins() async {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insertNodePosition(
            nodeId: 7, latitude: 50.0, longitude: 8.0, altitude: 100,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now.addingTimeInterval(-3_600)
        )
        database.insertNodePosition(
            nodeId: 7, latitude: 50.5, longitude: 8.5, altitude: 150,
            groundSpeed: 3, groundTrack: 90, timestamp: Self.now.addingTimeInterval(-60)
        )

        let positions = await database.latestNodePositions()
        #expect(positions.count == 1)
        #expect(positions[7]?.latitude == 50.5)
        #expect(positions[7]?.longitude == 8.5)
        #expect(positions[7]?.altitude == 150)
    }

    @Test("latestNodePositions ignores rows older than the cutoff and 0/0 positions")
    func cutoffAndZeroIgnored() async {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insertNodePosition(
            nodeId: 8, latitude: 50.0, longitude: 8.0, altitude: nil,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now.addingTimeInterval(-31 * 86_400)
        )
        database.insertNodePosition(
            nodeId: 9, latitude: 0, longitude: 0, altitude: 0,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now
        )

        #expect(await database.latestNodePositions().isEmpty)
        #expect(await database.latestNodePositions(maxAgeDays: 60)[8]?.latitude == 50.0)
        #expect(database.rowCount(in: "node_positions") == 1)
    }

    @Test("Identical positions younger than ten minutes are stored once")
    func duplicatePositionsSkipped() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        for offset in [0.0, 60, 300, 700] {
            database.insertNodePosition(
                nodeId: 10, latitude: 50.0, longitude: 8.0, altitude: 100,
                groundSpeed: 0, groundTrack: 0, timestamp: Self.now.addingTimeInterval(offset)
            )
        }
        database.insertNodePosition(
            nodeId: 10, latitude: 50.1, longitude: 8.0, altitude: 100,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now.addingTimeInterval(710)
        )
        database.waitForPendingWrites()

        #expect(database.rowCount(in: "node_positions") == 3)
    }

    @Test("Retention cleanup removes old node positions")
    func retentionCoversPositions() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insertNodePosition(
            nodeId: 11, latitude: 50.0, longitude: 8.0, altitude: nil,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now.addingTimeInterval(-10 * 86_400)
        )
        database.insertNodePosition(
            nodeId: 12, latitude: 50.0, longitude: 8.0, altitude: nil,
            groundSpeed: 0, groundTrack: 0, timestamp: Self.now
        )
        database.runRetentionCleanup(retentionDays: 7, now: Self.now)
        database.waitForPendingWrites()

        #expect(database.rowCount(in: "node_positions") == 1)
    }

    // MARK: - Helpers

    private func makeNode(id: UInt32, longName: String = "Node") -> NodeInfo {
        NodeInfo(id: id, nodeId: String(format: "!%08x", id), shortName: "N", longName: longName)
    }

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-PositionTests-\(UUID().uuidString)", isDirectory: true)
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
        persistence: PersistenceController,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-PositionProtocolTests-\(UUID().uuidString)", isDirectory: true)
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

    private func user(longName: String) -> Meshtastic_User {
        var user = Meshtastic_User()
        user.longName = longName
        user.shortName = "U"
        return user
    }

    private func position(lat: Double, lon: Double, alt: Int32) -> Meshtastic_Position {
        var position = Meshtastic_Position()
        position.latitudeI = Int32((lat * 1e7).rounded())
        position.longitudeI = Int32((lon * 1e7).rounded())
        position.altitude = alt
        return position
    }

    private func ingest(
        portnum: Meshtastic_PortNum,
        payload: Data,
        from senderID: UInt32,
        packetID: UInt32,
        through service: MeshtasticProtocolService
    ) throws {
        var data = Meshtastic_Data()
        data.portnum = portnum
        data.payload = payload
        var packet = Meshtastic_MeshPacket()
        packet.from = senderID
        packet.to = UInt32.max
        packet.id = packetID
        packet.decoded = data
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.packet = packet
        service.onVirtualFromRadioPayload(try fromRadio.serializedData())
    }

    /// Polls Core Data until the node row exists (writes run on a background context).
    private func storedLatitude(nodeID: UInt32, in persistence: PersistenceController) async throws -> Double? {
        for _ in 0..<40 {
            let context = persistence.container.newBackgroundContext()
            let latitude: Double?? = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "MHNodeEntity")
                request.predicate = NSPredicate(format: "nodeNum == %lld", Int64(nodeID))
                guard let object = try context.fetch(request).first else { return nil }
                return .some(object.value(forKey: "latitude") as? Double)
            }
            if let latitude { return latitude }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
