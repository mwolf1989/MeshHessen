import CoreGraphics
import Foundation
import ImageIO

// Terrain elevation from the Mesh Hessen terrain-RGB tiles (port of the Windows client's
// `TerrainService.cs`).
//
// Public API (also used by plan 029, triangulation):
// - `TerrainService.shared.grid(covering:)` loads every tile covering a bounding box once
//   and returns one contiguous `TerrainGrid` (nil when no tile could be loaded).
// - `TerrainGrid.height(latitude:longitude:)` answers point queries bilinearly (metres
//   above sea level, nil outside the grid or where the DEM has no data). Grids are
//   immutable value types and `Sendable`, so a scan with millions of lookups can run off
//   the main actor without touching the service again.
// - `TerrainGrid.sampler` adapts a grid to the `(latitude, longitude) -> Double?` closure
//   shape used by `LinkProfile` / the C# `Func<double, double, double?>` helpers.

// MARK: - Bounds

/// Geographic bounding box in degrees.
struct TerrainBounds: Equatable, Sendable {
    var minLatitude: Double
    var minLongitude: Double
    var maxLatitude: Double
    var maxLongitude: Double

    init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = min(minLatitude, maxLatitude)
        self.minLongitude = min(minLongitude, maxLongitude)
        self.maxLatitude = max(minLatitude, maxLatitude)
        self.maxLongitude = max(minLongitude, maxLongitude)
    }

    /// The box spanned by two points (e.g. both ends of a link).
    init(latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double) {
        self.init(
            minLatitude: latitude1,
            minLongitude: longitude1,
            maxLatitude: latitude2,
            maxLongitude: longitude2
        )
    }

    /// Pads by 5 % of the span (at least 0.01°) so sampling near the edge stays inside the grid.
    func padded() -> TerrainBounds {
        let padLatitude = max((maxLatitude - minLatitude) * 0.05, 0.01)
        let padLongitude = max((maxLongitude - minLongitude) * 0.05, 0.01)
        return TerrainBounds(
            minLatitude: minLatitude - padLatitude,
            minLongitude: minLongitude - padLongitude,
            maxLatitude: maxLatitude + padLatitude,
            maxLongitude: maxLongitude + padLongitude
        )
    }
}

// MARK: - Tile math

/// Web-Mercator (slippy map) tile and pixel math.
enum TerrainTileMath {
    static let maxLatitude = 85.05112878

    /// Inclusive tile index range.
    struct TileRange: Equatable, Sendable {
        let zoom: Int
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int

        var tileCount: Int { (maxX - minX + 1) * (maxY - minY + 1) }

        func contains(_ other: TileRange) -> Bool {
            zoom == other.zoom
                && minX <= other.minX && maxX >= other.maxX
                && minY <= other.minY && maxY >= other.maxY
        }
    }

    /// Global Web-Mercator pixel coordinates of a point at `zoom`.
    static func globalPixel(
        latitude: Double,
        longitude: Double,
        zoom: Int,
        tileSize: Int = 256
    ) -> (x: Double, y: Double) {
        let world = Double(tileSize) * pow(2, Double(zoom))
        let clamped = min(max(latitude, -maxLatitude), maxLatitude)
        let x = (longitude + 180) / 360 * world
        let sinLatitude = sin(clamped * .pi / 180)
        let y = (0.5 - log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * .pi)) * world
        return (x, y)
    }

    /// Inverse of `globalPixel`.
    static func coordinate(
        globalPixelX x: Double,
        y: Double,
        zoom: Int,
        tileSize: Int = 256
    ) -> (latitude: Double, longitude: Double) {
        let world = Double(tileSize) * pow(2, Double(zoom))
        let longitude = x / world * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y / world))) * 180 / .pi
        return (latitude, longitude)
    }

    /// Tile containing a point, clamped to the valid index range.
    static func tile(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = 1 << zoom
        let pixel = globalPixel(latitude: latitude, longitude: longitude, zoom: zoom, tileSize: 1)
        let x = Int(floor(pixel.x))
        let y = Int(floor(pixel.y))
        return (min(max(x, 0), n - 1), min(max(y, 0), n - 1))
    }

    /// Tiles covering a bounding box at `zoom`.
    static func tileRange(covering bounds: TerrainBounds, zoom: Int) -> TileRange {
        let topLeft = tile(latitude: bounds.maxLatitude, longitude: bounds.minLongitude, zoom: zoom)
        let bottomRight = tile(latitude: bounds.minLatitude, longitude: bounds.maxLongitude, zoom: zoom)
        return TileRange(zoom: zoom, minX: topLeft.x, maxX: bottomRight.x, minY: topLeft.y, maxY: bottomRight.y)
    }

    /// The finest zoom between `maxZoom` and `minZoom` whose tile range has at most
    /// `maxTiles` tiles; nil when even `minZoom` needs more (absurd box — give up instead of OOM).
    static func bestTileRange(
        covering bounds: TerrainBounds,
        maxZoom: Int = TerrainService.maxZoom,
        minZoom: Int = TerrainService.minZoom,
        maxTiles: Int = TerrainService.maxTiles
    ) -> TileRange? {
        for zoom in stride(from: maxZoom, through: minZoom, by: -1) {
            let range = tileRange(covering: bounds, zoom: zoom)
            if range.tileCount <= maxTiles { return range }
        }
        return nil
    }
}

// MARK: - Grid

/// Decoded terrain-RGB height grid in Web-Mercator pixel space at one zoom level
/// (a contiguous tile block). Pure data and math — fetching lives in `TerrainService`.
/// NaN = no data (outside DEM coverage; the server answers 204 there).
struct TerrainGrid: Sendable {
    /// Row-major heights in metres, NaN = no data.
    let heights: [Float]
    let width: Int
    let height: Int
    /// Global Web-Mercator pixel of the grid's (0, 0) sample.
    let originX: Double
    let originY: Double
    let zoom: Int
    let tileSize: Int
    /// The tile block this grid was built from (nil for synthetic grids).
    var tileRange: TerrainTileMath.TileRange?

    init(
        heights: [Float],
        width: Int,
        height: Int,
        originX: Double,
        originY: Double,
        zoom: Int,
        tileSize: Int = 256,
        tileRange: TerrainTileMath.TileRange? = nil
    ) {
        precondition(heights.count == width * height, "TerrainGrid: heights.count must equal width × height")
        self.heights = heights
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.zoom = zoom
        self.tileSize = tileSize
        self.tileRange = tileRange
    }

    /// Mapbox terrain-RGB: h = −10000 + (R·65536 + G·256 + B) · 0.1 m.
    static func decodePixel(red: UInt8, green: UInt8, blue: UInt8) -> Float {
        Float(-10_000.0 + (Double(red) * 65_536 + Double(green) * 256 + Double(blue)) * 0.1)
    }

    /// Global Web-Mercator pixel coordinates of a point at this grid's zoom.
    func globalPixel(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        TerrainTileMath.globalPixel(latitude: latitude, longitude: longitude, zoom: zoom, tileSize: tileSize)
    }

    /// Bilinear elevation (m a.s.l.); nil outside the grid or where the DEM has no data.
    /// NaN-aware: a NaN corner falls back to the first valid corner (coverage edge).
    func height(latitude: Double, longitude: Double) -> Double? {
        let pixel = globalPixel(latitude: latitude, longitude: longitude)
        let fx = pixel.x - originX
        let fy = pixel.y - originY
        guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }

        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0)
        let ty = fy - Double(y0)

        var h00 = heights[y0 * width + x0]
        var h10 = heights[y0 * width + x1]
        var h01 = heights[y1 * width + x0]
        var h11 = heights[y1 * width + x1]

        guard let any = [h00, h10, h01, h11].first(where: { !$0.isNaN }) else { return nil }
        if h00.isNaN { h00 = any }
        if h10.isNaN { h10 = any }
        if h01.isNaN { h01 = any }
        if h11.isNaN { h11 = any }

        let top = Double(h00) + Double(h10 - h00) * tx
        let bottom = Double(h01) + Double(h11 - h01) * tx
        return top + (bottom - top) * ty
    }

    /// The grid as an elevation sampler `(latitude, longitude) -> metres?`.
    var sampler: @Sendable (Double, Double) -> Double? {
        let grid = self
        return { latitude, longitude in grid.height(latitude: latitude, longitude: longitude) }
    }

    /// Decodes one terrain-RGB tile (PNG/WebP/…) into heights, row-major.
    /// Returns nil when the data is not a square image.
    static func decodeTile(_ data: Data) -> (size: Int, heights: [Float])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = image.width
        guard size > 0, image.height == size else { return nil }

        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        // Terrain tiles are opaque, so premultiplication does not alter the RGB values.
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }

        var heights = [Float](repeating: .nan, count: size * size)
        for index in 0..<(size * size) {
            let offset = index * 4
            heights[index] = decodePixel(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
        }
        return (size, heights)
    }
}

// MARK: - Service

/// Elevation model from the Mesh Hessen terrain-RGB tiles (Mapbox encoding, z5–10,
/// SRTM 90 m, served at `/terrain/{z}/{x}/{y}` on the vector tile host). Loads all tiles
/// covering a bounding box once, decodes them into one contiguous grid and keeps the
/// most recent grids in memory. Tiles go through `VectorTileCacheService` (disk cache,
/// 204 missing markers, offline mode, user agent), so terrain works offline for any
/// area fetched once — this service never talks to the network itself.
actor TerrainService {
    static let shared = TerrainService()

    /// Source-sharp zoom: SRTM 90 m ≈ z10 pixel size.
    static let maxZoom = 10
    static let minZoom = 5
    /// ~20 MB decoded; larger boxes drop zoom.
    static let maxTiles = 80
    /// Terrain tile URL template on the Mesh Hessen vector host (the host of the official
    /// vector styles). Also used for the 3D terrain `raster-dem` source on the vector map.
    static let tileURLTemplate: String = {
        let styleURL = URL(string: MapTileSource.osm.meshHessenVectorStyleURL)
        let host = styleURL?.host ?? "vectortile.meshhessenclient.de"
        let scheme = styleURL?.scheme ?? "https"
        return "\(scheme)://\(host)/terrain/{z}/{x}/{y}"
    }()

    static func tileURL(zoom: Int, x: Int, y: Int) -> URL? {
        URL(string: tileURLTemplate
            .replacingOccurrences(of: "{z}", with: String(zoom))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y)))
    }

    private let cache: VectorTileCacheService
    private let memoryLimit: Int
    private var recentGrids: [TerrainGrid] = []

    init(cache: VectorTileCacheService = .shared, memoryLimit: Int = 4) {
        self.cache = cache
        self.memoryLimit = max(1, memoryLimit)
    }

    /// Mirrors the app's offline map mode onto the shared resource cache (no network when true).
    func setOfflineOnly(_ value: Bool) async {
        await cache.setOfflineOnly(value)
    }

    /// Height grid covering `bounds` (padded slightly). Returns nil when nothing is
    /// available (offline without cache, fully outside coverage, or an absurd box).
    func grid(covering bounds: TerrainBounds) async -> TerrainGrid? {
        guard let range = TerrainTileMath.bestTileRange(covering: bounds.padded()) else {
            AppLogger.shared.log("[Terrain] bounding box too large for z\(Self.minZoom)")
            return nil
        }
        if let index = recentGrids.firstIndex(where: { $0.tileRange?.contains(range) == true }) {
            let grid = recentGrids.remove(at: index)
            recentGrids.insert(grid, at: 0)
            return grid
        }
        guard let grid = await load(range) else { return nil }
        recentGrids.insert(grid, at: 0)
        if recentGrids.count > memoryLimit { recentGrids.removeLast(recentGrids.count - memoryLimit) }
        return grid
    }

    /// Drops the in-memory grids (the disk cache is untouched).
    func clearMemory() {
        recentGrids.removeAll()
    }

    // MARK: - Private

    private func load(_ range: TerrainTileMath.TileRange) async -> TerrainGrid? {
        let tilesX = range.maxX - range.minX + 1
        let tilesY = range.maxY - range.minY + 1
        var heights: [Float] = []
        var tileSize = 0
        var width = 0
        var loaded = 0

        for tileY in range.minY...range.maxY {
            for tileX in range.minX...range.maxX {
                if Task.isCancelled { return nil }
                guard let url = Self.tileURL(zoom: range.zoom, x: tileX, y: tileY) else { continue }
                let response: VectorResourceResponse
                do {
                    response = try await cache.response(for: url, resourceType: .tile)
                } catch {
                    AppLogger.shared.log("[Terrain] tile \(range.zoom)/\(tileX)/\(tileY) failed: \(error)")
                    continue
                }
                // 204 = outside coverage → the block stays NaN.
                guard response.statusCode == 200, let body = response.body, !body.isEmpty else { continue }
                guard let tile = TerrainGrid.decodeTile(body) else {
                    AppLogger.shared.log("[Terrain] tile \(range.zoom)/\(tileX)/\(tileY) could not be decoded")
                    continue
                }
                if heights.isEmpty {
                    tileSize = tile.size
                    width = tilesX * tileSize
                    heights = [Float](repeating: .nan, count: width * tilesY * tileSize)
                }
                guard tile.size == tileSize else { continue }

                let offsetX = (tileX - range.minX) * tileSize
                let offsetY = (tileY - range.minY) * tileSize
                heights.withUnsafeMutableBufferPointer { destination in
                    tile.heights.withUnsafeBufferPointer { source in
                        for row in 0..<tileSize {
                            let target = (offsetY + row) * width + offsetX
                            let start = row * tileSize
                            for column in 0..<tileSize {
                                destination[target + column] = source[start + column]
                            }
                        }
                    }
                }
                loaded += 1
            }
        }

        guard loaded > 0 else {
            AppLogger.shared.log("[Terrain] no terrain data for z\(range.zoom) \(range.minX)-\(range.maxX)/\(range.minY)-\(range.maxY)")
            return nil
        }
        return TerrainGrid(
            heights: heights,
            width: width,
            height: tilesY * tileSize,
            originX: Double(range.minX * tileSize),
            originY: Double(range.minY * tileSize),
            zoom: range.zoom,
            tileSize: tileSize,
            tileRange: range
        )
    }
}
