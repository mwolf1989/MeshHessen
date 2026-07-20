import Foundation
import Testing

@testable import MeshHessen

@Suite("T-Deck Tile Assistant")
struct TDeckTileServiceTests {
    @Test("Slippy-map coordinates are clamped and deterministic")
    func tileCoordinates() {
        #expect(TDeckTileService.tileCoordinate(latitude: 0, longitude: 0, zoom: 0) == .init(zoom: 0, x: 0, y: 0))
        #expect(TDeckTileService.tileCoordinate(latitude: 0, longitude: 0, zoom: 1) == .init(zoom: 1, x: 1, y: 1))
        #expect(TDeckTileService.tileCoordinate(latitude: 90, longitude: 180, zoom: 2).x == 3)
    }

    @Test("German state selections form their geographic union")
    func stateUnion() throws {
        let hessen = try #require(TDeckGermanState.all.first { $0.name == "Hessen" })
        let bavaria = try #require(TDeckGermanState.all.first { $0.name == "Bayern" })
        let union = try #require(TDeckBounds.union([hessen.bounds, bavaria.bounds]))

        #expect(union.north == max(hessen.bounds.north, bavaria.bounds.north))
        #expect(union.south == min(hessen.bounds.south, bavaria.bounds.south))
        #expect(union.east == max(hessen.bounds.east, bavaria.bounds.east))
        #expect(union.west == min(hessen.bounds.west, bavaria.bounds.west))
    }

    @Test("Tile estimates include every zoom level")
    func estimate() {
        let z1 = TDeckTileService.estimatedTileCount(
            bounds: TDeckBounds.germany,
            maximumZoom: 1
        )
        let z4 = TDeckTileService.estimatedTileCount(
            bounds: TDeckBounds.germany,
            maximumZoom: 4
        )

        #expect(z1 > 0)
        #expect(z4 > z1)
        #expect(TDeckTileService.estimatedSizeBytes(tileCount: z4) == Int64(z4) * 15_000)
    }

    @Test("T-Deck SD paths match the firmware folder convention")
    func sdPath() {
        let root = URL(fileURLWithPath: "/Volumes/SD")
        let tile = TDeckTileCoordinate(zoom: 12, x: 2_133, y: 1_402)
        let url = TDeckTileService.sdTileURL(root: root, source: .topographic, tile: tile)

        #expect(url.path == "/Volumes/SD/maps/OpenTopo/12/2133/1402.png")
    }

    @Test("Public community servers are rejected for bulk downloads")
    func publicServerPolicy() {
        #expect(TDeckTileService.isPublicTileServer("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
        #expect(TDeckTileService.isPublicTileServer("https://a.tile.opentopomap.org/{z}/{x}/{y}.png"))
        #expect(!TDeckTileService.isPublicTileServer("https://tile.meshhessenclient.de/osm/{z}/{x}/{y}.png"))
        #expect(!TDeckTileService.isPublicTileServer("https://example.test/cache/openstreetmap.org/{z}/{x}/{y}.png"))
    }

    @Test("Cached tiles copy additively without network access")
    func cachedTransfer() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdeck-test-\(UUID().uuidString)", isDirectory: true)
        let cache = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let destination = temporaryRoot.appendingPathComponent("sd", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bounds = TDeckBounds(north: 1, south: -1, east: 1, west: -1)
        let range = TDeckTileService.tileRange(bounds: bounds, zoom: 1)
        for x in range.x {
            for y in range.y {
                let tile = TDeckTileCoordinate(zoom: 1, x: x, y: y)
                let cacheURL = TDeckTileService.cacheTileURL(root: cache, source: .osm, tile: tile)
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cacheURL)
            }
        }

        let service = TDeckTileService()
        try await service.transferTiles(
            source: .osm,
            bounds: bounds,
            maximumZoom: 1,
            destinationRoot: destination,
            cacheRoot: cache,
            urlTemplate: "https://invalid.example/{z}/{x}/{y}.png"
        ) { progress in
            #expect(progress.source == .localCache)
        }

        let firstTile = TDeckTileCoordinate(zoom: 1, x: range.x.lowerBound, y: range.y.lowerBound)
        #expect(FileManager.default.fileExists(
            atPath: TDeckTileService.sdTileURL(root: destination, source: .osm, tile: firstTile).path
        ))
    }

    @Test("Cache export creates a valid ZIP container")
    func zipExport() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdeck-zip-test-\(UUID().uuidString)", isDirectory: true)
        let cache = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let output = temporaryRoot.appendingPathComponent("tiles.zip")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let tile = TDeckTileCoordinate(zoom: 1, x: 1, y: 1)
        let cacheURL = TDeckTileService.cacheTileURL(root: cache, source: .osm, tile: tile)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cacheURL)

        try await TDeckTileService().exportCachedTiles(to: output, cacheRoot: cache) { _, _, _ in }
        let zip = try Data(contentsOf: output)

        #expect(zip.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #expect(zip.range(of: Data("osm/1/1/1.png".utf8)) != nil)
        #expect(zip.suffix(22).starts(with: [0x50, 0x4B, 0x05, 0x06]))
    }
}
