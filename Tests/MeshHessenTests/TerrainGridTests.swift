import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MeshHessen

/// Terrain-RGB decoding and bilinear sampling of the in-memory height grid
/// (port of `TerrainGridTests.cs`), plus tile math and the cache-backed loader.
@Suite("Terrain grid")
struct TerrainGridTests {
    private static let zoom = 10
    private static let tileSize = 256

    private static func pixelToCoordinate(_ x: Double, _ y: Double) -> (latitude: Double, longitude: Double) {
        TerrainTileMath.coordinate(globalPixelX: x, y: y, zoom: zoom, tileSize: tileSize)
    }

    private static func origin() -> (x: Double, y: Double) {
        let pixel = TerrainTileMath.globalPixel(latitude: 50, longitude: 8, zoom: zoom, tileSize: tileSize)
        return (floor(pixel.x), floor(pixel.y))
    }

    private static func grid(_ heights: [Float], width: Int = 2, height: Int = 2) -> TerrainGrid {
        let origin = origin()
        return TerrainGrid(
            heights: heights,
            width: width,
            height: height,
            originX: origin.x,
            originY: origin.y,
            zoom: zoom,
            tileSize: tileSize
        )
    }

    @Test("Mapbox RGB decoding matches the formula")
    func decodingMatchesFormula() {
        #expect(abs(TerrainGrid.decodePixel(red: 1, green: 134, blue: 160) - 0) < 0.001)       // sea level
        #expect(abs(TerrainGrid.decodePixel(red: 1, green: 168, blue: 166) - 871) < 0.001)     // Großer Feldberg
        #expect(abs(TerrainGrid.decodePixel(red: 0, green: 0, blue: 0) - -10_000) < 0.001)
    }

    @Test("Bilinear sampling interpolates between pixels")
    func bilinearSampling() throws {
        let origin = Self.origin()
        let grid = Self.grid([100, 200, 300, 400])

        let corner = Self.pixelToCoordinate(origin.x, origin.y)
        #expect(abs(try #require(grid.height(latitude: corner.latitude, longitude: corner.longitude)) - 100) < 0.5)

        let middle = Self.pixelToCoordinate(origin.x + 0.5, origin.y + 0.5)
        #expect(abs(try #require(grid.height(latitude: middle.latitude, longitude: middle.longitude)) - 250) < 0.5)

        let outside = Self.pixelToCoordinate(origin.x + 10, origin.y)
        #expect(grid.height(latitude: outside.latitude, longitude: outside.longitude) == nil)
    }

    @Test("Missing corners fall back instead of poisoning")
    func missingCornersFallBack() {
        let origin = Self.origin()
        let middle = Self.pixelToCoordinate(origin.x + 0.5, origin.y + 0.5)

        let edge = Self.grid([.nan, 200, 300, 400])
        #expect(edge.height(latitude: middle.latitude, longitude: middle.longitude) != nil)

        let dead = Self.grid([.nan, .nan, .nan, .nan])
        #expect(dead.height(latitude: middle.latitude, longitude: middle.longitude) == nil)
    }

    @Test("Tile math round-trips and finds the containing tile")
    func tileMath() {
        let pixel = TerrainTileMath.globalPixel(latitude: 50.1, longitude: 8.7, zoom: 10)
        let back = TerrainTileMath.coordinate(globalPixelX: pixel.x, y: pixel.y, zoom: 10)
        #expect(abs(back.latitude - 50.1) < 1e-9)
        #expect(abs(back.longitude - 8.7) < 1e-9)

        // Frankfurt am Main at z10 is tile 536/346.
        let tile = TerrainTileMath.tile(latitude: 50.1109, longitude: 8.6821, zoom: 10)
        #expect(tile.x == 536)
        #expect(tile.y == 346)
    }

    @Test("Zoom drops until the box needs at most 80 tiles")
    func zoomSelection() throws {
        let small = TerrainBounds(minLatitude: 50.0, minLongitude: 8.0, maxLatitude: 50.1, maxLongitude: 8.2)
        let smallRange = try #require(TerrainTileMath.bestTileRange(covering: small))
        #expect(smallRange.zoom == 10)

        let large = TerrainBounds(minLatitude: 49.0, minLongitude: 7.0, maxLatitude: 51.5, maxLongitude: 10.5)
        let largeRange = try #require(TerrainTileMath.bestTileRange(covering: large))
        #expect(largeRange.zoom < 10)
        #expect(largeRange.tileCount <= 80)
        let finer = TerrainTileMath.tileRange(covering: large, zoom: largeRange.zoom + 1)
        #expect(finer.tileCount > 80)

        let world = TerrainBounds(minLatitude: -80, minLongitude: -179, maxLatitude: 80, maxLongitude: 179)
        #expect(TerrainTileMath.bestTileRange(covering: world) == nil)
    }

    @Test("A PNG tile decodes to the encoded heights")
    func pngTileDecodes() throws {
        let data = try Self.terrainPNG(size: 4) { x, y in Double(100 * y + x) }
        let tile = try #require(TerrainGrid.decodeTile(data))
        #expect(tile.size == 4)
        #expect(abs(tile.heights[0] - 0) < 0.11)
        #expect(abs(tile.heights[1] - 1) < 0.11)
        #expect(abs(tile.heights[4] - 100) < 0.11)      // row 1 = second image row from the top
        #expect(abs(tile.heights[15] - 303) < 0.11)
        #expect(TerrainGrid.decodeTile(Data("not an image".utf8)) == nil)
    }

    @Test("The service loads tiles only through the resource cache and stitches them")
    func serviceLoadsThroughCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bounds = TerrainBounds(latitude1: 50.0, longitude1: 8.5, latitude2: 50.3, longitude2: 9.0)
        let range = try #require(TerrainTileMath.bestTileRange(covering: bounds.padded()))
        #expect(range.maxX > range.minX && range.maxY > range.minY)
        // One tile is outside coverage (204), all others have a constant 250 m.
        let tile = try Self.terrainPNG(size: 256) { _, _ in 250 }
        let client = TerrainStubHTTPClient(tile: tile, missingTile: (range.minX, range.minY))
        let cache = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let service = TerrainService(cache: cache)

        let grid = try #require(await service.grid(covering: bounds))
        #expect(grid.zoom == range.zoom)
        #expect(grid.width == (range.maxX - range.minX + 1) * 256)
        let elevation = try #require(grid.height(latitude: 50.02, longitude: 8.98))
        #expect(abs(elevation - 250) < 0.11)

        let requests = await client.requestedURLs
        #expect(requests.count == range.tileCount)
        #expect(requests.allSatisfy { $0.host == "vectortile.meshhessenclient.de" && $0.path.hasPrefix("/terrain/\(range.zoom)/") })

        // Memoised: a second query for the same area does not touch the cache again.
        _ = await service.grid(covering: bounds)
        #expect(await client.requestedURLs.count == range.tileCount)
    }

    @Test("No tile available means no grid")
    func noTilesMeansNil() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: TerrainStubHTTPClient(tile: nil))
        let service = TerrainService(cache: cache)
        let bounds = TerrainBounds(latitude1: 55.0, longitude1: 8.0, latitude2: 55.01, longitude2: 8.01)
        #expect(await service.grid(covering: bounds) == nil)
    }

    // MARK: - Fixtures

    /// Builds an opaque terrain-RGB PNG whose pixel (x, y) encodes `height(x, y)` metres.
    static func terrainPNG(size: Int, height: (Int, Int) -> Double) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value = Int(((height(x, y) + 10_000) / 0.1).rounded())
                let offset = (y * size + x) * 4
                pixels[offset] = UInt8((value >> 16) & 0xFF)
                pixels[offset + 1] = UInt8((value >> 8) & 0xFF)
                pixels[offset + 2] = UInt8(value & 0xFF)
            }
        }
        let image = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// Serves the same terrain tile for every request (or 204 when `tile` is nil / for `missingTile`).
private actor TerrainStubHTTPClient: VectorTileHTTPClient {
    private let tile: Data?
    private let missingTile: (x: Int, y: Int)?
    private(set) var requestedURLs: [URL] = []

    init(tile: Data?, missingTile: (Int, Int)? = nil) {
        self.tile = tile
        self.missingTile = missingTile.map { (x: $0.0, y: $0.1) }
    }

    func data(for request: URLRequest) async throws -> VectorHTTPClientResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        requestedURLs.append(url)
        let components = url.pathComponents
        let isMissing = missingTile.map {
            components.suffix(2) == [String($0.x), String($0.y)]
        } ?? false
        guard let tile, !isMissing else {
            return VectorHTTPClientResponse(data: Data(), statusCode: 204, reasonPhrase: "No Content", headers: [:])
        }
        return VectorHTTPClientResponse(
            data: tile,
            statusCode: 200,
            reasonPhrase: "OK",
            headers: ["Content-Type": "image/png"]
        )
    }
}
