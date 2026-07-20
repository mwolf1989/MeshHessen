import Foundation
import Testing

@testable import MeshHessen

@Suite("Map and Offline Parity")
struct MapOfflineParityTests {
    @Test("Slippy-map coordinates match the XYZ scheme")
    func tileCoordinates() {
        #expect(TileCoordinateCalculator.coordinate(latitude: 0, longitude: 0, zoom: 1) == .init(x: 1, y: 1, zoom: 1))
        #expect(TileCoordinateCalculator.coordinate(latitude: 90, longitude: -180, zoom: 2) == .init(x: 0, y: 0, zoom: 2))
        #expect(TileCoordinateCalculator.coordinate(latitude: -90, longitude: 180, zoom: 2) == .init(x: 3, y: 3, zoom: 2))
    }

    @Test("Hessen default selection has the Windows-compatible tile estimate")
    func hessenTileEstimate() {
        let count = TileCoordinateCalculator.estimatedTileCount(
            bounds: .hessen,
            minimumZoom: 1,
            maximumZoom: 14
        )
        #expect(count == 25_671)
        #expect(TileCoordinateCalculator.coordinates(bounds: .hessen, minimumZoom: 1, maximumZoom: 14).count == count)
    }

    @Test("Areas crossing the antimeridian use both edge ranges")
    func antimeridianCoordinates() {
        let bounds = MapBounds(north: 10, south: -10, east: -170, west: 170)
        let coordinates = TileCoordinateCalculator.coordinates(bounds: bounds, minimumZoom: 2, maximumZoom: 2)
        #expect(!coordinates.isEmpty)
        #expect(coordinates.contains { $0.x == 0 })
        #expect(coordinates.contains { $0.x == 3 })
        #expect(Set(coordinates).count == coordinates.count)
    }

    @Test("Public community servers are detected by host, not path text")
    func publicServerDetection() {
        #expect(MapTilePolicy.isPublicTileServer("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
        #expect(MapTilePolicy.isPublicTileServer("https://a.tile.openstreetmap.org/{z}/{x}/{y}.png"))
        #expect(MapTilePolicy.isPublicTileServer("https://tile.opentopomap.org/{z}/{x}/{y}.png"))
        #expect(!MapTilePolicy.isPublicTileServer("https://tiles.example.org/openstreetmap.org/{z}/{x}/{y}.png"))
        #expect(!MapTilePolicy.isPublicTileServer("https://notopenstreetmap.org/{z}/{x}/{y}.png"))
    }

    @Test("Official Mesh Hessen endpoints remain independent of custom settings")
    func officialMeshHessenEndpoints() {
        #expect(MapTileSource.osm.meshHessenRasterURLTemplate == "https://tile.meshhessenclient.de/osm/{z}/{x}/{y}.png")
        #expect(MapTileSource.topographic.meshHessenRasterURLTemplate.contains("/opentopo/"))
        #expect(MapTileSource.dark.meshHessenVectorStyleURL.hasSuffix("/styles/dark.json"))
        #expect(!MapTilePolicy.isPublicTileServer(MapTileSource.osm.meshHessenRasterURLTemplate))
    }

    @Test("Bulk download policy blocks public OSM and validates templates")
    func bulkDownloadPolicy() throws {
        let publicOSM = MapTileSourceDescriptor(
            source: .osm,
            urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        )
        #expect(throws: OfflineMapError.publicBulkDownloadForbidden) {
            try MapTilePolicy.ensureBulkDownloadAllowed(for: publicOSM)
        }

        let ownServer = MapTileSourceDescriptor(
            source: .osm,
            urlTemplate: "https://tile.meshhessenclient.de/osm/{z}/{x}/{y}.png"
        )
        try MapTilePolicy.ensureBulkDownloadAllowed(for: ownServer)

        #expect(throws: OfflineMapError.invalidURLTemplate) {
            try MapTilePolicy.validateTemplate("http://example.org/{z}/{x}/{y}.png")
        }
        #expect(throws: OfflineMapError.invalidURLTemplate) {
            try MapTilePolicy.validateTemplate("https://example.org/tiles.png")
        }
    }

    @Test("Public cache metadata never expires before seven days")
    func publicCacheLifetime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let short = MapTilePolicy.cacheExpiry(cacheControl: "public, max-age=60", expires: nil, now: now)
        let long = MapTilePolicy.cacheExpiry(cacheControl: "max-age=864000", expires: nil, now: now)
        #expect(short == now.addingTimeInterval(7 * 24 * 60 * 60))
        #expect(long == now.addingTimeInterval(10 * 24 * 60 * 60))
    }

    @Test("Offline package metadata round-trips without losing bounds")
    func metadataRoundTrip() throws {
        let package = OfflineMapPackage(
            name: "Hessen",
            source: .topographic,
            bounds: .hessen,
            minimumZoom: 1,
            maximumZoom: 14,
            tileCount: 25_671,
            byteCount: 123_456,
            attribution: MapTileSourceDescriptor.defaultAttribution(for: .topographic)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(OfflineMapPackage.self, from: encoder.encode(package))

        #expect(restored.id == package.id)
        #expect(restored.name == package.name)
        #expect(restored.source == package.source)
        #expect(restored.bounds == package.bounds)
        #expect(restored.minimumZoom == package.minimumZoom)
        #expect(restored.maximumZoom == package.maximumZoom)
        #expect(restored.tileCount == package.tileCount)
        #expect(restored.byteCount == package.byteCount)
        #expect(abs(restored.createdAt.timeIntervalSince(package.createdAt)) < 1)
        #expect(restored.bounds == .hessen)
        #expect(restored.formatVersion == OfflineMapPackage.formatVersion)
    }

    @Test("Windows-style tile ZIP imports and exports as a managed package")
    func legacyZIPImportExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapOfflineParityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let tile = legacy.appendingPathComponent("osm/1/0/0.png")
        try FileManager.default.createDirectory(at: tile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tile)
        let inputZIP = root.appendingPathComponent("windows-maptiles.zip")
        try MapZIPArchive.create(from: legacy, at: inputZIP)

        let service = OfflineMapService(rootDirectory: root.appendingPathComponent("store"))
        let imported = try await service.importPackage(from: inputZIP) { _ in }
        #expect(imported.source == .osm)
        #expect(imported.tileCount == 1)
        #expect(imported.minimumZoom == 1)
        #expect(imported.maximumZoom == 1)
        #expect(try await service.packages().count == 1)

        let outputZIP = root.appendingPathComponent("export.zip")
        try await service.exportPackage(imported, to: outputZIP) { _ in }
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        let extraction = try MapZIPArchive.extract(from: outputZIP, to: extracted)
        #expect(extraction.paths.contains(OfflineMapPackage.manifestFilename))
        #expect(extraction.paths.contains("tiles/osm/1/0/0.png"))
    }

    @Test("Emergency overlay decoder supports nodes and way centers")
    func emergencyDecoder() throws {
        let json = Data(
            """
            {"elements":[
              {"type":"node","id":1,"lat":50.1,"lon":8.6,"tags":{"emergency":"fire_hydrant","ref":"H-1"}},
              {"type":"way","id":2,"center":{"lat":50.2,"lon":8.7},"tags":{"amenity":"fire_station","name":"Feuerwehr"}}
            ]}
            """.utf8
        )

        let features = try EmergencyFeatureService.decodeResponse(json)

        #expect(features.count == 2)
        #expect(features[0].kind == .hydrant)
        #expect(features[1].kind == .fireStation)
        #expect(features[1].name == "Feuerwehr")
    }

    @Test("Emergency overlay supports the Windows feature classes and zoom thresholds")
    func emergencyFeatureClasses() throws {
        let json = Data(
            """
            {"elements":[
              {"type":"node","id":1,"lat":50.1,"lon":8.6,"tags":{"emergency":"water_tank","water_volume":"50000","operator":"Feuerwehr"}},
              {"type":"node","id":2,"lat":50.2,"lon":8.7,"tags":{"emergency":"fire_extinguisher","location":"Foyer"}},
              {"type":"node","id":3,"lat":50.3,"lon":8.8,"tags":{"emergency":"assembly_point","ref":"SP-7"}}
            ]}
            """.utf8
        )

        let features = try EmergencyFeatureService.decodeResponse(json)

        #expect(features.map(\.kind) == [.waterTank, .fireExtinguisher, .assemblyPoint])
        #expect(features[0].kind.minimumZoom == 14)
        #expect(features[1].kind.minimumZoom == 16)
        #expect(features[2].kind.minimumZoom == 13)
        #expect(features[0].details["water_volume"] == "50000")
        #expect(features[1].localizedDetailText.contains("Foyer"))
    }

    @Test("Vector offline plans include the Windows basemap, topo, and emergency sources")
    func vectorOfflinePlans() {
        let request = VectorOfflineDownloadRequest(
            bounds: .hessen,
            maximumDetailZoom: 14,
            includeTopography: true,
            includeEmergencyFeatures: true
        )
        let plans = VectorOfflinePackageDownloaderService.plans(for: request)

        #expect(plans.contains(.init(source: "basemap", minimumZoom: 1, maximumZoom: 14)))
        #expect(plans.contains(.init(source: "contours", minimumZoom: 11, maximumZoom: 14)))
        #expect(plans.contains(.init(source: "hillshade", minimumZoom: 1, maximumZoom: 14)))
        #expect(plans.contains(.init(source: "emergency", minimumZoom: 13, maximumZoom: 14)))
        #expect(VectorOfflinePackageDownloaderService.estimatedResourceCount(for: request) > 25_671)
    }
}
