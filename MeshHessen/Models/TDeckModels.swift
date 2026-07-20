import Foundation

enum TDeckMapSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case osm
    case dark
    case topographic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .osm:         return String(localized: "OpenStreetMap")
        case .dark:        return String(localized: "OSM Dark")
        case .topographic: return String(localized: "OpenTopoMap")
        }
    }

    var cacheFolderName: String {
        switch self {
        case .osm:         return "osm"
        case .dark:        return "osmdark"
        case .topographic: return "osmtopo"
        }
    }

    var sdCardFolderName: String {
        switch self {
        case .osm:         return "OSM"
        case .dark:        return "OSMDark"
        case .topographic: return "OpenTopo"
        }
    }

    func urlTemplate(settings: SettingsService = .shared) -> String {
        switch self {
        case .osm:         return settings.osmTileURL
        case .dark:        return settings.darkTileURL
        case .topographic: return settings.topographicTileURL
        }
    }
}

enum TDeckRegionMode: String, CaseIterable, Identifiable, Sendable {
    case germanStates
    case germany
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .germanStates: return String(localized: "German states")
        case .germany:     return String(localized: "All of Germany")
        case .custom:      return String(localized: "Custom coordinates")
        }
    }
}

struct TDeckBounds: Hashable, Codable, Sendable {
    var north: Double
    var south: Double
    var east: Double
    var west: Double

    static let germany = Self(north: 55.0997, south: 47.2701, east: 15.0419, west: 5.8660)

    var isValid: Bool {
        (-90...90).contains(north)
            && (-90...90).contains(south)
            && (-180...180).contains(east)
            && (-180...180).contains(west)
            && north > south
            && east > west
    }

    static func union(_ bounds: [TDeckBounds]) -> TDeckBounds? {
        guard let first = bounds.first else { return nil }
        return bounds.dropFirst().reduce(first) { result, next in
            TDeckBounds(
                north: max(result.north, next.north),
                south: min(result.south, next.south),
                east: max(result.east, next.east),
                west: min(result.west, next.west)
            )
        }
    }
}

struct TDeckGermanState: Identifiable, Hashable, Sendable {
    let name: String
    let bounds: TDeckBounds

    var id: String { name }

    static let all: [Self] = [
        .init(name: "Baden-Württemberg", bounds: .init(north: 49.7913, south: 47.5324, east: 10.4923, west: 7.5114)),
        .init(name: "Bayern", bounds: .init(north: 50.5648, south: 47.2703, east: 13.8395, west: 8.9766)),
        .init(name: "Berlin", bounds: .init(north: 52.6754, south: 52.3383, east: 13.7612, west: 13.0883)),
        .init(name: "Brandenburg", bounds: .init(north: 53.5588, south: 51.3595, east: 14.7654, west: 11.2668)),
        .init(name: "Bremen", bounds: .init(north: 53.2282, south: 53.0059, east: 8.9910, west: 8.4817)),
        .init(name: "Hamburg", bounds: .init(north: 53.7444, south: 53.3951, east: 10.3257, west: 9.7312)),
        .init(name: "Hessen", bounds: .init(north: 51.6567, south: 49.3951, east: 10.2367, west: 7.7731)),
        .init(name: "Mecklenburg-Vorpommern", bounds: .init(north: 54.6850, south: 53.1148, east: 14.4127, west: 10.5930)),
        .init(name: "Niedersachsen", bounds: .init(north: 53.8941, south: 51.2955, east: 11.5978, west: 6.6541)),
        .init(name: "Nordrhein-Westfalen", bounds: .init(north: 52.5314, south: 50.3228, east: 9.4614, west: 5.8660)),
        .init(name: "Rheinland-Pfalz", bounds: .init(north: 50.9391, south: 48.9667, east: 8.5077, west: 6.1131)),
        .init(name: "Saarland", bounds: .init(north: 49.6399, south: 49.1119, east: 7.4036, west: 6.3626)),
        .init(name: "Sachsen", bounds: .init(north: 51.6853, south: 50.1713, east: 15.0376, west: 11.8726)),
        .init(name: "Sachsen-Anhalt", bounds: .init(north: 53.0410, south: 50.9380, east: 13.1877, west: 10.5631)),
        .init(name: "Schleswig-Holstein", bounds: .init(north: 55.0583, south: 53.3595, east: 11.3102, west: 7.8700)),
        .init(name: "Thüringen", bounds: .init(north: 51.6488, south: 50.2004, east: 12.6534, west: 9.8774)),
    ]
}

struct TDeckTileCoordinate: Hashable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int
}

struct TDeckTransferProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let tile: TDeckTileCoordinate
    let source: Source

    enum Source: String, Equatable, Sendable {
        case alreadyOnCard
        case localCache
        case downloaded
        case failed
    }

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

struct TDeckVolumeInfo: Equatable, Sendable {
    let name: String
    let formatDescription: String
    let totalBytes: Int64?
    let availableBytes: Int64?
    let isReadOnly: Bool

    var isTDeckCompatible: Bool {
        let normalized = formatDescription.lowercased()
        return normalized.contains("exfat")
            || normalized.contains("fat32")
            || normalized.contains("ms-dos")
            || normalized.contains("msdos")
    }
}
