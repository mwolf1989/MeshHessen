import Foundation
import Testing

@testable import MeshHessen

@Suite("Traceroute History Parity")
struct TracerouteHistoryParityTests {
    @Test("history periods cover 3, 7, 14, 30, 90 days and all")
    func historyPeriods() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let results = [2, 4, 8, 15, 31, 91].enumerated().map { index, age in
            makeResult(
                id: uuid(index + 1),
                sourceNodeId: 1,
                targetNodeId: UInt32(index + 2),
                receivedAt: now.addingTimeInterval(-Double(age) * 86_400)
            )
        }

        #expect(query(.last3Days).apply(to: results, now: now).count == 1)
        #expect(query(.last7Days).apply(to: results, now: now).count == 2)
        #expect(query(.last14Days).apply(to: results, now: now).count == 3)
        #expect(query(.last30Days).apply(to: results, now: now).count == 4)
        #expect(query(.last90Days).apply(to: results, now: now).count == 5)
        #expect(query(.all).apply(to: results, now: now).count == 6)
    }

    @Test("deduplication keeps the newest route for a direction-independent node pair")
    func pairDeduplication() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldPairResult = makeResult(
            id: uuid(1),
            sourceNodeId: 10,
            targetNodeId: 20,
            receivedAt: now.addingTimeInterval(-300)
        )
        let newestReverseResult = makeResult(
            id: uuid(2),
            sourceNodeId: 20,
            targetNodeId: 10,
            receivedAt: now.addingTimeInterval(-100)
        )
        let otherPairResult = makeResult(
            id: uuid(3),
            sourceNodeId: 10,
            targetNodeId: 30,
            receivedAt: now.addingTimeInterval(-200)
        )

        let filtered = TracerouteHistoryQuery(period: .all, newestPerNodePair: true)
            .apply(to: [oldPairResult, otherPairResult, newestReverseResult], now: now)

        #expect(filtered.map(\.id) == [newestReverseResult.id, otherPairResult.id])
        #expect(filtered.allSatisfy { $0.id != oldPairResult.id })
    }

    @Test("native store preserves complete results and deletes selected IDs")
    func storeRoundTripAndDelete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TracerouteStore(storageDirectory: directory)
        let result = makeResult(
            id: uuid(12),
            sourceNodeId: 0x1111,
            targetNodeId: 0x2222,
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mqtt: true
        )

        try store.persist(result)
        #expect(store.loadReport().results == [result])

        try store.delete(ids: [result.id])
        #expect(store.loadAll().isEmpty)
    }

    @Test("portable export imports multiple selected results")
    func bulkExportImport() throws {
        let sourceDirectory = temporaryDirectory()
        let destinationDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourceStore = TracerouteStore(storageDirectory: sourceDirectory)
        let destinationStore = TracerouteStore(storageDirectory: destinationDirectory)
        let first = makeResult(
            id: uuid(1),
            sourceNodeId: 1,
            targetNodeId: 2,
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let second = makeResult(
            id: uuid(2),
            sourceNodeId: 1,
            targetNodeId: 3,
            receivedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let data = try sourceStore.exportData(for: [first, second])
        let imported = try destinationStore.importData(data)

        #expect(Set(imported.map(\.id)) == Set([first.id, second.id]))
        #expect(destinationStore.loadAll().count == 2)
    }

    @Test("legacy macOS single-result JSON remains readable")
    func legacyMacJSON() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TracerouteStore(storageDirectory: directory)
        let legacy = LegacyTracerouteResult(
            id: uuid(5),
            requestTime: Date(timeIntervalSince1970: 1_700_000_000),
            targetNodeId: 42,
            targetName: "Legacy",
            hops: [
                .init(
                    id: uuid(6),
                    nodeId: 42,
                    nodeName: "Legacy",
                    snr: 2.5,
                    latitude: 50.1,
                    longitude: 8.6,
                    viaMqtt: false
                ),
            ],
            responseTime: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let data = try JSONEncoder().encode(legacy)
        let imported = try store.importData(data)

        #expect(imported.count == 1)
        #expect(imported[0].id == legacy.id)
        #expect(imported[0].sourceNodeId == nil)
        #expect(imported[0].requestId == nil)
        #expect(imported[0].hops[0].distanceToNext == nil)
    }

    @Test("Windows TracerouteSaveData JSON imports names, positions and scaled SNR")
    func windowsJSONCompatibility() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TracerouteStore(storageDirectory: directory)
        let json = """
        {
          "Result": {
            "RequestId": 77,
            "DestinationNodeId": 300,
            "SourceNodeId": 100,
            "IsViaMqtt": true,
            "ReceivedAt": "2026-07-20T10:11:12.345Z",
            "RouteForward": [200, 300],
            "SnrTowards": [12, -8],
            "RouteBack": [300, 200],
            "SnrBack": [-4, 8]
          },
          "DestinationName": "Ziel",
          "Nodes": [
            { "NodeId": 200, "Name": "Relay", "Lat": 50.0, "Lon": 8.0 },
            { "NodeId": 300, "Name": "Ziel", "Lat": 50.1, "Lon": 8.1 }
          ]
        }
        """
        let data = Data(json.utf8)

        let firstImport = try store.importData(data)
        let secondImport = try store.importData(data)
        let result = try #require(firstImport.first)

        #expect(secondImport.first?.id == result.id)
        #expect(result.requestId == 77)
        #expect(result.sourceNodeId == 100)
        #expect(result.targetNodeId == 300)
        #expect(result.targetName == "Ziel")
        #expect(result.hops.map(\.nodeName) == ["Relay", "Ziel"])
        #expect(result.hops[0].snr == 3)
        #expect(result.hops[1].snr == -2)
        #expect(result.hops.allSatisfy { $0.viaMqtt })
        #expect(store.loadAll().count == 1)
    }

    @Test("a corrupt JSON file does not hide valid history")
    func corruptFileIsolation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TracerouteStore(storageDirectory: directory)
        let valid = makeResult(
            id: uuid(1),
            sourceNodeId: 1,
            targetNodeId: 2,
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.persist(valid)
        try Data("{not-json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let report = store.loadReport()

        #expect(report.results == [valid])
        #expect(report.failures.count == 1)
        #expect(report.failures[0].fileURL.lastPathComponent == "broken.json")
    }

    @Test("selection resolves multiple saved routes in history order")
    func selectionResolution() {
        let first = makeResult(id: uuid(1), sourceNodeId: 1, targetNodeId: 2, receivedAt: .distantPast)
        let second = makeResult(id: uuid(2), sourceNodeId: 1, targetNodeId: 3, receivedAt: .distantFuture)
        var selection = TracerouteSelection()
        selection.setSelected(true, result: second)
        selection.setSelected(true, result: first)

        #expect(selection.count == 2)
        #expect(selection.resolve(in: [first, second]).map(\.id) == [first.id, second.id])

        selection.setSelected(false, result: first)
        #expect(selection.resolve(in: [first, second]) == [second])
    }

    @Test("hop distance uses positioned endpoints")
    func positionedHopDistance() {
        let first = TracerouteHop(nodeId: 1, nodeName: "A", latitude: 0, longitude: 0)
        let second = TracerouteHop(nodeId: 2, nodeName: "B", latitude: 0, longitude: 0.01)
        let distance = first.distance(to: second)

        #expect(distance != nil)
        #expect(abs((distance ?? 0) - 1_111.95) < 1)
    }

    @Test("firmware unknown-hop sentinels do not become nodes or SNR readings")
    func unknownHopSentinels() {
        let hop = TracerouteHop(
            nodeId: TracerouteHop.unknownNodeId,
            nodeName: "Unknown",
            snr: TracerouteHop.decodedSNR(Int32(Int8.min))
        )

        #expect(hop.isUnknown)
        #expect(hop.snr == nil)
        #expect(hop.resolvedPosition(fallbackLatitude: 50, fallbackLongitude: 8) == nil)
        #expect(TracerouteHop.decodedSNR(57) == 14.25)
    }

    @Test("a trace hop can use a position learned after the trace completed")
    func hopPositionFallback() throws {
        let hop = TracerouteHop(nodeId: 42, nodeName: "Relay")
        let position = try #require(
            hop.resolvedPosition(fallbackLatitude: 50.123, fallbackLongitude: 8.456)
        )

        #expect(position.latitude == 50.123)
        #expect(position.longitude == 8.456)
    }

    private func query(_ period: TracerouteHistoryPeriod) -> TracerouteHistoryQuery {
        TracerouteHistoryQuery(period: period, newestPerNodePair: false)
    }

    private func makeResult(
        id: UUID,
        sourceNodeId: UInt32,
        targetNodeId: UInt32,
        receivedAt: Date,
        mqtt: Bool = false
    ) -> TracerouteResult {
        TracerouteResult(
            id: id,
            requestId: UInt32(id.uuidString.suffix(2), radix: 16),
            requestTime: receivedAt.addingTimeInterval(-0.5),
            sourceNodeId: sourceNodeId,
            targetNodeId: targetNodeId,
            targetName: "Node \(targetNodeId)",
            hops: [
                TracerouteHop(
                    id: uuid(Int(targetNodeId % 100) + 100),
                    nodeId: targetNodeId,
                    nodeName: "Node \(targetNodeId)",
                    snr: 4.5,
                    latitude: 50.0,
                    longitude: 8.0,
                    viaMqtt: mqtt,
                    distanceToNext: 123
                ),
            ],
            responseTime: receivedAt
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-TracerouteTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number)) ?? UUID()
    }
}

private struct LegacyTracerouteResult: Codable {
    let id: UUID
    let requestTime: Date
    let targetNodeId: UInt32
    let targetName: String
    let hops: [LegacyTracerouteHop]
    let responseTime: Date?
}

private struct LegacyTracerouteHop: Codable {
    let id: UUID
    let nodeId: UInt32
    let nodeName: String
    let snr: Float?
    let latitude: Double?
    let longitude: Double?
    let viaMqtt: Bool
}
