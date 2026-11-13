import Foundation
import Testing

@testable import MeshHessen

/// Direct-RF link evidence (`rf_links` / `rf_link_obs`): upsert semantics, direction
/// mapping, collection start, first-seen and traceroute pairing.
@Suite("RF Links")
struct RfLinkTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-RfLinkTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("telemetry.sqlite")
        return (
            TelemetryDatabaseService(databaseURL: url, retentionDays: 0, clock: { Self.now }),
            directory
        )
    }

    // MARK: - Upsert

    @Test("A repeated upsert updates the row instead of duplicating it")
    func upsertUpdatesExistingRow() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .rx, timestamp: Self.now.addingTimeInterval(-600))
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 7.5, source: .rx, timestamp: Self.now)

        let rows = await db.rfNeighbors(of: 1)
        let partner = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(partner.neighborId == 2)
        #expect(partner.snrIn == 7.5)
        #expect(partner.sources == [.rx])
        #expect(partner.lastSeen == Self.now)
        #expect(db.rowCount(in: "rf_links") == 1)
    }

    @Test("A missing SNR keeps the previous value")
    func nilSnrKeepsPreviousValue() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .rx, timestamp: Self.now.addingTimeInterval(-600))
        db.upsertRfLink(observer: 1, neighbor: 2, snr: nil, source: .rx, timestamp: Self.now)

        let partner = try #require(await db.rfNeighbors(of: 1).first)
        #expect(partner.snrIn == 5)
    }

    @Test("SNR 0 means no measurement: stored as NULL, never overwrites, no history")
    func snrZeroIsNull() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 0, source: .neighborInfo, timestamp: Self.now)
        var partner = try #require(await db.rfNeighbors(of: 1).first)
        #expect(partner.snrIn == nil)
        #expect(db.rowCount(in: "rf_link_obs") == 0)

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 4.5, source: .neighborInfo, timestamp: Self.now)
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 0, source: .neighborInfo, timestamp: Self.now)
        partner = try #require(await db.rfNeighbors(of: 1).first)
        #expect(partner.snrIn == 4.5)
        #expect(db.rowCount(in: "rf_link_obs") == 1)
    }

    @Test("Observation history is kept only for traceroute and NeighborInfo with a real SNR")
    func historyPerObservation() {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 4, source: .traceroute, timestamp: Self.now.addingTimeInterval(-7_200))
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 6, source: .traceroute, timestamp: Self.now.addingTimeInterval(-3_600))
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 8, source: .neighborInfo, timestamp: Self.now)
        db.upsertRfLink(observer: 1, neighbor: 2, snr: nil, source: .traceroute, timestamp: Self.now)
        db.upsertRfLink(observer: 1, neighbor: 3, snr: 3, source: .rx, timestamp: Self.now)
        db.waitForPendingWrites()

        #expect(db.rowCount(in: "rf_link_obs") == 3)
        #expect(db.rowCount(in: "rf_links") == 3)
    }

    @Test("Self links and zero node IDs are ignored")
    func selfLinksAndZeroIdsIgnored() async {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 1, snr: 5, source: .rx, timestamp: Self.now)
        db.upsertRfLink(observer: 0, neighbor: 2, snr: 5, source: .rx, timestamp: Self.now)
        db.upsertRfLink(observer: 1, neighbor: 0, snr: 5, source: .rx, timestamp: Self.now)

        #expect(await db.rfNeighbors(of: 1).isEmpty)
        #expect(await db.rfLinkCollectionStart() == nil)
    }

    // MARK: - Neighbours

    @Test("Directions map to SNR in and out and swap for the other node")
    func directionsMerge() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 3, source: .rx, timestamp: Self.now)
        db.upsertRfLink(observer: 2, neighbor: 1, snr: -6.5, source: .neighborInfo, timestamp: Self.now)

        let fromOne = try #require(await db.rfNeighbors(of: 1).first)
        #expect(fromOne.snrIn == 3)
        #expect(fromOne.snrOut == -6.5)
        #expect(Set(fromOne.sources) == [.rx, .neighborInfo])

        let fromTwo = try #require(await db.rfNeighbors(of: 2).first)
        #expect(fromTwo.neighborId == 1)
        #expect(fromTwo.snrIn == -6.5)
        #expect(fromTwo.snrOut == 3)
    }

    @Test("The newest source wins the SNR snapshot")
    func newestSourceWins() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 9, source: .neighborInfo, timestamp: Self.now.addingTimeInterval(-7_200))
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 3, source: .traceroute, timestamp: Self.now)

        let partner = try #require(await db.rfNeighbors(of: 1).first)
        #expect(partner.snrIn == 3)
    }

    @Test("The time window filters stale links; newest partners come first")
    func windowFiltersStaleLinks() async {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .rx, timestamp: Self.now.addingTimeInterval(-10 * 86_400))
        db.upsertRfLink(observer: 1, neighbor: 3, snr: 2, source: .traceroute, timestamp: Self.now)

        let recent = await db.rfNeighbors(of: 1, since: Self.now.addingTimeInterval(-7 * 86_400))
        #expect(recent.map(\.neighborId) == [3])
        #expect(await db.rfNeighbors(of: 1).map(\.neighborId) == [3, 2])
    }

    @Test("The collection start marker is set once and survives later inserts")
    func collectionStartMarker() async {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await db.rfLinkCollectionStart() == nil)
        let first = Self.now.addingTimeInterval(-9 * 86_400)
        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .rx, timestamp: first)
        db.upsertRfLink(observer: 1, neighbor: 3, snr: 2, source: .rx, timestamp: Self.now)

        let start = await db.rfLinkCollectionStart()
        #expect(start.map { abs($0.timeIntervalSince(first)) < 1 } == true)
    }

    @Test("Clearing telemetry empties both link tables and resets the collection start")
    func clearResetsLinks() async throws {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .traceroute, timestamp: Self.now)
        #expect(try await db.clearAllTelemetry() == 2)
        #expect(db.rowCount(in: "rf_links") == 0)
        #expect(db.rowCount(in: "rf_link_obs") == 0)
        #expect(await db.rfLinkCollectionStart() == nil)
    }

    @Test("Retention trims observation history but keeps the link snapshot")
    func retentionKeepsLinks() {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        db.upsertRfLink(observer: 1, neighbor: 2, snr: 5, source: .traceroute, timestamp: Self.now.addingTimeInterval(-40 * 86_400))
        db.waitForPendingWrites()
        db.runRetentionCleanup(retentionDays: 30, now: Self.now)
        db.waitForPendingWrites()

        #expect(db.rowCount(in: "rf_link_obs") == 0)
        #expect(db.rowCount(in: "rf_links") == 1)
    }

    // MARK: - Display rule

    @Test("RF links replace own contacts with three links or after a week of collection")
    func displayRule() {
        let now = Self.now
        let young = now.addingTimeInterval(-86_400)
        let old = now.addingTimeInterval(-8 * 86_400)
        #expect(RfNeighbor.shouldUseRfLinks(linkCount: 3, collectionStart: nil, now: now))
        #expect(RfNeighbor.shouldUseRfLinks(linkCount: 3, collectionStart: young, now: now))
        #expect(!RfNeighbor.shouldUseRfLinks(linkCount: 2, collectionStart: young, now: now))
        #expect(RfNeighbor.shouldUseRfLinks(linkCount: 1, collectionStart: old, now: now))
        #expect(!RfNeighbor.shouldUseRfLinks(linkCount: 0, collectionStart: old, now: now))
        #expect(!RfNeighbor.shouldUseRfLinks(linkCount: 2, collectionStart: nil, now: now))
    }

    // MARK: - First seen

    @Test("First seen is the earliest stored packet of the node")
    func firstSeen() async {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await db.firstSeen(nodeId: 7) == nil)
        for (index, offset) in [-600.0, -86_400, -60].enumerated() {
            db.insertPacketRx(
                nodeId: 7,
                packetId: UInt32(index + 1),
                timestamp: Self.now.addingTimeInterval(offset),
                snr: 4,
                rssi: -90,
                hopCount: 0,
                wantAck: false
            )
        }
        #expect(await db.firstSeen(nodeId: 7) == Self.now.addingTimeInterval(-86_400))
        #expect(await db.firstSeen(nodeId: 8) == nil)
    }

    // MARK: - Traceroute pairing

    private func route(
        _ forward: [UInt32], _ towards: [Int32],
        back: [UInt32] = [], _ snrBack: [Int32] = []
    ) -> Meshtastic_RouteDiscovery {
        var route = Meshtastic_RouteDiscovery()
        route.route = forward
        route.snrTowards = towards
        route.routeBack = back
        route.snrBack = snrBack
        return route
    }

    @Test("Forward and return paths pair receiver (observer) with sender (neighbor)")
    func traceroutePairing() {
        // me(1) → 10 → 20 → target(2), and back 2 → 30 → 1
        let links = MeshtasticProtocolService.tracerouteLinks(
            source: 1,
            destination: 2,
            route: route([10, 20], [24, -26, 8], back: [30], [12, -4])
        )
        #expect(links == [
            RfLinkObservation(observer: 10, neighbor: 1, snr: 6),
            RfLinkObservation(observer: 20, neighbor: 10, snr: -6.5),
            RfLinkObservation(observer: 2, neighbor: 20, snr: 2),
            RfLinkObservation(observer: 30, neighbor: 2, snr: 3),
            RfLinkObservation(observer: 1, neighbor: 30, snr: -1),
        ])
    }

    @Test("Direct traceroute without hops yields one link per direction")
    func directTraceroute() {
        let links = MeshtasticProtocolService.tracerouteLinks(
            source: 1, destination: 2, route: route([], [20], back: [], [-8])
        )
        #expect(links == [
            RfLinkObservation(observer: 2, neighbor: 1, snr: 5),
            RfLinkObservation(observer: 1, neighbor: 2, snr: -2),
        ])
    }

    @Test("Non-RF segments, missing SNRs and unknown hops are skipped")
    func tracerouteSkipsNonRf() {
        let unknown = TracerouteHop.unknownNodeId
        let links = MeshtasticProtocolService.tracerouteLinks(
            source: 1,
            destination: 2,
            // 1→10: sentinel; 10→unknown: real but unknown hop; unknown→2: missing SNR
            route: route([10, unknown], [-128, 16])
        )
        #expect(links.isEmpty)

        let mqttLeg = MeshtasticProtocolService.tracerouteLinks(
            source: 1, destination: 2, route: route([10], [0, 12])
        )
        #expect(mqttLeg == [RfLinkObservation(observer: 2, neighbor: 10, snr: 3)])
    }

    @Test("Non-RF SNR detection covers the sentinel and zero")
    func nonRfSnr() {
        #expect(MeshtasticProtocolService.isNonRfSnr(-128))
        #expect(MeshtasticProtocolService.isNonRfSnr(0))
        #expect(!MeshtasticProtocolService.isNonRfSnr(1))
        #expect(!MeshtasticProtocolService.isNonRfSnr(-127))
        #expect(!MeshtasticProtocolService.isNonRfSnr(-26))
    }
}
