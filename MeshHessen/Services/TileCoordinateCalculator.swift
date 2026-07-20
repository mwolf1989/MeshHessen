import Foundation

enum TileCoordinateCalculator {
    static let maximumMercatorLatitude = 85.05112878
    static let maximumOfflineTileCount = 2_000_000

    static func coordinate(latitude: Double, longitude: Double, zoom: Int) -> MapTileCoordinate {
        let safeZoom = max(0, min(30, zoom))
        let count = 1 << safeZoom
        let latitude = max(-maximumMercatorLatitude, min(maximumMercatorLatitude, latitude))
        let longitude = max(-180, min(180, longitude))
        let latitudeRadians = latitude * .pi / 180

        let rawX = Int(floor((longitude + 180) / 360 * Double(count)))
        let mercator = log(tan(latitudeRadians) + 1 / cos(latitudeRadians))
        let rawY = Int(floor((1 - mercator / .pi) / 2 * Double(count)))

        return MapTileCoordinate(
            x: max(0, min(count - 1, rawX)),
            y: max(0, min(count - 1, rawY)),
            zoom: safeZoom
        )
    }

    static func coordinates(
        bounds: MapBounds,
        minimumZoom: Int,
        maximumZoom: Int
    ) -> [MapTileCoordinate] {
        guard bounds.isValid, minimumZoom >= 0, maximumZoom >= minimumZoom else {
            return []
        }

        var result: [MapTileCoordinate] = []
        result.reserveCapacity(
            min(
                maximumOfflineTileCount,
                estimatedTileCount(bounds: bounds, minimumZoom: minimumZoom, maximumZoom: maximumZoom)
            )
        )

        for zoom in minimumZoom...maximumZoom {
            let northWest = coordinate(latitude: bounds.north, longitude: bounds.west, zoom: zoom)
            let southEast = coordinate(latitude: bounds.south, longitude: bounds.east, zoom: zoom)
            let yRange = min(northWest.y, southEast.y)...max(northWest.y, southEast.y)

            for xRange in xRanges(bounds: bounds, zoom: zoom) {
                for x in xRange {
                    for y in yRange {
                        result.append(.init(x: x, y: y, zoom: zoom))
                    }
                }
            }
        }
        return result
    }

    static func estimatedTileCount(
        bounds: MapBounds,
        minimumZoom: Int,
        maximumZoom: Int
    ) -> Int {
        guard bounds.isValid, minimumZoom >= 0, maximumZoom >= minimumZoom else {
            return 0
        }

        var total = 0
        for zoom in minimumZoom...maximumZoom {
            let northWest = coordinate(latitude: bounds.north, longitude: bounds.west, zoom: zoom)
            let southEast = coordinate(latitude: bounds.south, longitude: bounds.east, zoom: zoom)
            let yCount = abs(southEast.y - northWest.y) + 1
            let xCount = xRanges(bounds: bounds, zoom: zoom).reduce(0) { partial, range in
                partial + range.count
            }
            let (product, overflow) = xCount.multipliedReportingOverflow(by: yCount)
            if overflow || total > Int.max - product {
                return Int.max
            }
            total += product
        }
        return total
    }

    static func bounds(containing coordinates: [MapTileCoordinate]) -> MapBounds? {
        guard let first = coordinates.first else { return nil }
        var north = -90.0
        var south = 90.0
        var east = -180.0
        var west = 180.0

        for coordinate in coordinates {
            let tileBounds = bounds(for: coordinate)
            north = max(north, tileBounds.north)
            south = min(south, tileBounds.south)
            east = max(east, tileBounds.east)
            west = min(west, tileBounds.west)
        }

        let result = MapBounds(north: north, south: south, east: east, west: west)
        return result.isValid && first.zoom >= 0 ? result : nil
    }

    static func bounds(for coordinate: MapTileCoordinate) -> MapBounds {
        let count = pow(2.0, Double(coordinate.zoom))
        let west = Double(coordinate.x) / count * 360 - 180
        let east = Double(coordinate.x + 1) / count * 360 - 180
        let north = latitude(forTileY: Double(coordinate.y), tileCount: count)
        let south = latitude(forTileY: Double(coordinate.y + 1), tileCount: count)
        return MapBounds(north: north, south: south, east: east, west: west)
    }

    private static func xRanges(bounds: MapBounds, zoom: Int) -> [ClosedRange<Int>] {
        let west = coordinate(latitude: 0, longitude: bounds.west, zoom: zoom).x
        let east = coordinate(latitude: 0, longitude: bounds.east, zoom: zoom).x
        guard bounds.crossesAntimeridian else {
            return [min(west, east)...max(west, east)]
        }

        let maximum = (1 << zoom) - 1
        return [west...maximum, 0...east]
    }

    private static func latitude(forTileY y: Double, tileCount: Double) -> Double {
        atan(sinh(.pi * (1 - 2 * y / tileCount))) * 180 / .pi
    }
}
