import Foundation

// MARK: - Tile source

enum MapTileSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case osm
    case topographic = "osmtopo"
    case dark = "osmdark"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .osm: return String(localized: "OpenStreetMap")
        case .topographic: return String(localized: "OpenTopoMap")
        case .dark: return String(localized: "OpenStreetMap Dark")
        }
    }

    var fileExtension: String { "png" }

    /// Official community endpoints used by the Windows client's `online-own` mode.
    /// Keeping these separate from the configurable endpoints ensures switching to
    /// "Mesh Hessen server" always restores the trusted service.
    var meshHessenRasterURLTemplate: String {
        switch self {
        case .osm:
            return "https://tile.meshhessenclient.de/osm/{z}/{x}/{y}.png"
        case .topographic:
            return "https://tile.meshhessenclient.de/opentopo/{z}/{x}/{y}.png"
        case .dark:
            return "https://tile.meshhessenclient.de/dark/{z}/{x}/{y}.png"
        }
    }

    var meshHessenVectorStyleURL: String {
        switch self {
        case .osm:
            return "https://vectortile.meshhessenclient.de/styles/osm.json"
        case .topographic:
            return "https://vectortile.meshhessenclient.de/styles/opentopo.json"
        case .dark:
            return "https://vectortile.meshhessenclient.de/styles/dark.json"
        }
    }

    init(style: MeshMapStyle) {
        switch style {
        case .osm: self = .osm
        case .topography: self = .topographic
        case .dark: self = .dark
        }
    }
}

struct MapTileSourceDescriptor: Codable, Equatable, Identifiable, Sendable {
    var source: MapTileSource
    var urlTemplate: String
    var attribution: String
    var minimumZoom: Int
    var maximumZoom: Int
    var followsPublicOSMPolicy: Bool

    var id: String { "\(source.rawValue)|\(urlTemplate)" }

    init(
        source: MapTileSource,
        urlTemplate: String,
        attribution: String? = nil,
        minimumZoom: Int = 1,
        maximumZoom: Int = 19,
        followsPublicOSMPolicy: Bool? = nil
    ) {
        self.source = source
        self.urlTemplate = urlTemplate
        self.attribution = attribution ?? Self.defaultAttribution(for: source)
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.followsPublicOSMPolicy = followsPublicOSMPolicy
            ?? MapTilePolicy.isPublicTileServer(urlTemplate)
    }

    static func defaultAttribution(for source: MapTileSource) -> String {
        switch source {
        case .osm, .dark:
            return "© OpenStreetMap contributors"
        case .topographic:
            return "© OpenStreetMap contributors, SRTM | © OpenTopoMap (CC-BY-SA)"
        }
    }
}

// MARK: - Coordinates and bounds

struct MapTileCoordinate: Codable, Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var zoom: Int
}

struct MapBounds: Codable, Equatable, Sendable {
    var north: Double
    var south: Double
    var east: Double
    var west: Double

    static let hessen = MapBounds(north: 51.7, south: 49.4, east: 10.3, west: 7.8)

    var isValid: Bool {
        north.isFinite
            && south.isFinite
            && east.isFinite
            && west.isFinite
            && north > south
            && north <= 90
            && south >= -90
            && east >= -180
            && east <= 180
            && west >= -180
            && west <= 180
    }

    var crossesAntimeridian: Bool { east < west }

    var centerLatitude: Double { (north + south) / 2 }

    var centerLongitude: Double {
        guard crossesAntimeridian else { return (east + west) / 2 }
        let shiftedEast = east + 360
        let center = (shiftedEast + west) / 2
        return center > 180 ? center - 360 : center
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        guard latitude >= south, latitude <= north else { return false }
        if crossesAntimeridian {
            return longitude >= west || longitude <= east
        }
        return longitude >= west && longitude <= east
    }
}

struct MapRegionPreset: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let bounds: MapBounds

    static let germanStates: [MapRegionPreset] = [
        .init(name: "Baden-Württemberg", bounds: .init(north: 49.8, south: 47.5, east: 10.5, west: 7.5)),
        .init(name: "Bayern", bounds: .init(north: 50.6, south: 47.3, east: 13.8, west: 8.9)),
        .init(name: "Berlin", bounds: .init(north: 52.7, south: 52.3, east: 13.8, west: 13.1)),
        .init(name: "Brandenburg", bounds: .init(north: 53.6, south: 51.4, east: 14.8, west: 11.3)),
        .init(name: "Bremen", bounds: .init(north: 53.6, south: 53.0, east: 8.9, west: 8.5)),
        .init(name: "Hamburg", bounds: .init(north: 53.8, south: 53.4, east: 10.3, west: 9.7)),
        .init(name: "Hessen", bounds: .hessen),
        .init(name: "Mecklenburg-Vorpommern", bounds: .init(north: 54.7, south: 53.1, east: 14.4, west: 10.6)),
        .init(name: "Niedersachsen", bounds: .init(north: 53.9, south: 51.3, east: 11.6, west: 6.7)),
        .init(name: "Nordrhein-Westfalen", bounds: .init(north: 52.5, south: 50.3, east: 9.5, west: 5.9)),
        .init(name: "Rheinland-Pfalz", bounds: .init(north: 50.9, south: 48.9, east: 8.5, west: 6.1)),
        .init(name: "Saarland", bounds: .init(north: 49.6, south: 49.1, east: 7.4, west: 6.4)),
        .init(name: "Sachsen", bounds: .init(north: 51.7, south: 50.2, east: 15.0, west: 11.9)),
        .init(name: "Sachsen-Anhalt", bounds: .init(north: 53.0, south: 50.9, east: 13.2, west: 10.6)),
        .init(name: "Schleswig-Holstein", bounds: .init(north: 55.1, south: 53.4, east: 11.3, west: 8.4)),
        .init(name: "Thüringen", bounds: .init(north: 51.6, south: 50.2, east: 12.7, west: 9.9)),
    ]
}

// MARK: - Offline package

struct OfflineMapPackage: Codable, Equatable, Identifiable, Sendable {
    static let manifestFilename = "manifest.json"
    static let formatVersion = 1

    var id: UUID
    var formatVersion: Int
    var name: String
    var source: MapTileSource
    var bounds: MapBounds
    var minimumZoom: Int
    var maximumZoom: Int
    var tileCount: Int
    var byteCount: Int64
    var createdAt: Date
    var attribution: String

    init(
        id: UUID = UUID(),
        name: String,
        source: MapTileSource,
        bounds: MapBounds,
        minimumZoom: Int,
        maximumZoom: Int,
        tileCount: Int = 0,
        byteCount: Int64 = 0,
        createdAt: Date = Date(),
        attribution: String = "© OpenStreetMap contributors"
    ) {
        self.id = id
        self.formatVersion = Self.formatVersion
        self.name = name
        self.source = source
        self.bounds = bounds
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.tileCount = tileCount
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.attribution = attribution
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct OfflineMapDownloadRequest: Equatable, Sendable {
    var name: String
    var descriptor: MapTileSourceDescriptor
    var bounds: MapBounds
    var minimumZoom: Int
    var maximumZoom: Int

    var estimatedTileCount: Int {
        TileCoordinateCalculator.estimatedTileCount(
            bounds: bounds,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom
        )
    }
}

struct OfflineMapProgress: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing
        case downloading
        case importing
        case exporting
        case finished
    }

    var phase: Phase
    var completed: Int
    var total: Int
    var status: String

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum OfflineMapError: LocalizedError, Equatable {
    case invalidBounds
    case invalidZoomRange
    case invalidURLTemplate
    case publicBulkDownloadForbidden
    case packageTooLarge(Int)
    case packageNotFound
    case invalidPackage
    case archiveContainsUnsafePath
    case unsupportedArchiveCompression(UInt16)
    case noTiles
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidBounds:
            return String(localized: "The selected map area is invalid.")
        case .invalidZoomRange:
            return String(localized: "The selected zoom range is invalid.")
        case .invalidURLTemplate:
            return String(localized: "The tile URL must be HTTPS and contain {z}, {x}, and {y}.")
        case .publicBulkDownloadForbidden:
            return String(localized: "Bulk downloads from public OSM/OpenTopoMap servers are prohibited by their tile usage policy.")
        case .packageTooLarge(let count):
            return String(localized: "This selection contains \(count) tiles. Choose a smaller area or zoom range.")
        case .packageNotFound:
            return String(localized: "The offline map package could not be found.")
        case .invalidPackage:
            return String(localized: "The selected file is not a valid MeshHessen map package.")
        case .archiveContainsUnsafePath:
            return String(localized: "The archive contains an unsafe file path.")
        case .unsupportedArchiveCompression(let method):
            return String(localized: "The ZIP compression method \(method) is not supported.")
        case .noTiles:
            return String(localized: "The package does not contain map tiles.")
        case .network(let message):
            return message
        }
    }
}

// MARK: - Emergency overlay

enum EmergencyFeatureKind: String, Codable, Sendable {
    case hydrant
    case defibrillator
    case emergencyPhone
    case suctionPoint
    case waterTank
    case fireWaterPond
    case fireStation
    case rescueStation
    case siren
    case rescuePoint
    case assemblyPoint
    case disasterHelpPoint
    case mountainRescue
    case landingSite
    case lifeguard
    case ladderSite
    case fireServiceInlet
    case fireExtinguisher
    case fireAlarmBox
    case fireHose
    case keyDepot
    case lifeRing
    case firstAidKit
    case hospital
    case other

    var symbolName: String {
        switch self {
        case .hydrant: return "drop.fill"
        case .defibrillator: return "heart.fill"
        case .emergencyPhone: return "phone.fill"
        case .suctionPoint: return "water.waves"
        case .waterTank: return "cylinder.fill"
        case .fireWaterPond: return "drop.circle.fill"
        case .fireStation: return "flame.fill"
        case .rescueStation: return "cross.case.fill"
        case .siren: return "speaker.wave.3.fill"
        case .rescuePoint: return "cross.circle.fill"
        case .assemblyPoint: return "person.3.fill"
        case .disasterHelpPoint: return "cross.vial.fill"
        case .mountainRescue: return "mountain.2.fill"
        case .landingSite: return "h.circle.fill"
        case .lifeguard, .lifeRing: return "lifepreserver.fill"
        case .ladderSite: return "figure.climbing"
        case .fireServiceInlet: return "arrow.down.to.line.circle.fill"
        case .fireExtinguisher: return "fire.extinguisher.fill"
        case .fireAlarmBox: return "bell.and.waves.left.and.right.fill"
        case .fireHose: return "hose.fill"
        case .keyDepot: return "key.fill"
        case .firstAidKit: return "cross.case.fill"
        case .hospital: return "cross.fill"
        case .other: return "exclamationmark.triangle.fill"
        }
    }

    /// Matches the visibility thresholds of the Windows vector overlay.
    var minimumZoom: Int {
        switch self {
        case .hydrant, .defibrillator, .emergencyPhone:
            return 15
        case .suctionPoint, .waterTank, .lifeguard, .ladderSite:
            return 14
        case .fireServiceInlet, .fireExtinguisher, .fireAlarmBox,
             .fireHose, .keyDepot, .lifeRing, .firstAidKit:
            return 16
        case .fireWaterPond, .fireStation, .rescueStation, .siren,
             .rescuePoint, .assemblyPoint, .disasterHelpPoint,
             .mountainRescue, .landingSite, .hospital, .other:
            return 13
        }
    }

    /// Feuerwehrplan convention: red = fire response, blue = water,
    /// green = rescue, orange = civil protection.
    var markerColorHex: String {
        switch self {
        case .suctionPoint, .waterTank, .fireWaterPond, .emergencyPhone:
            return "#1976D2"
        case .defibrillator, .rescuePoint, .assemblyPoint, .lifeguard,
             .lifeRing, .firstAidKit:
            return "#2E7D32"
        case .disasterHelpPoint:
            return "#EF6C00"
        case .hydrant, .fireStation, .rescueStation, .siren, .mountainRescue,
             .landingSite, .ladderSite, .fireServiceInlet, .fireExtinguisher,
             .fireAlarmBox, .fireHose, .keyDepot, .hospital, .other:
            return "#C62828"
        }
    }

    var localizedName: String {
        switch self {
        case .hydrant: return String(localized: "Hydrant")
        case .defibrillator: return String(localized: "Defibrillator (AED)")
        case .emergencyPhone: return String(localized: "Emergency phone")
        case .suctionPoint: return String(localized: "Suction point")
        case .waterTank: return String(localized: "Fire-water tank")
        case .fireWaterPond: return String(localized: "Fire-water pond")
        case .fireStation: return String(localized: "Fire station")
        case .rescueStation: return String(localized: "Ambulance station")
        case .siren: return String(localized: "Siren")
        case .rescuePoint: return String(localized: "Rescue point")
        case .assemblyPoint: return String(localized: "Assembly point")
        case .disasterHelpPoint: return String(localized: "Disaster help point")
        case .mountainRescue: return String(localized: "Mountain rescue")
        case .landingSite: return String(localized: "Helicopter landing site")
        case .lifeguard: return String(localized: "Lifeguard")
        case .ladderSite: return String(localized: "Ladder site")
        case .fireServiceInlet: return String(localized: "Fire-service inlet")
        case .fireExtinguisher: return String(localized: "Fire extinguisher")
        case .fireAlarmBox: return String(localized: "Fire alarm box")
        case .fireHose: return String(localized: "Fire hose")
        case .keyDepot: return String(localized: "Fire-service key depot")
        case .lifeRing: return String(localized: "Life ring")
        case .firstAidKit: return String(localized: "First-aid kit")
        case .hospital: return String(localized: "Hospital")
        case .other: return String(localized: "Emergency facility")
        }
    }
}

struct EmergencyMapFeature: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: EmergencyFeatureKind
    var name: String
    var latitude: Double
    var longitude: Double
    var details: [String: String]

    var localizedDetailText: String {
        details
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\(Self.localizedDetailName($0.key)): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func localizedDetailName(_ key: String) -> String {
        switch key {
        case "name": return String(localized: "Name")
        case "ref": return String(localized: "Number")
        case "type", "fire_hydrant:type": return String(localized: "Type")
        case "couplings": return String(localized: "Couplings")
        case "colour": return String(localized: "Colour")
        case "water_source": return String(localized: "Water source")
        case "flow_rate": return String(localized: "Flow rate")
        case "pressure": return String(localized: "Pressure")
        case "water_volume": return String(localized: "Water volume")
        case "operator": return String(localized: "Operator")
        case "opening_hours": return String(localized: "Opening hours")
        case "location": return String(localized: "Location")
        case "level": return String(localized: "Level")
        case "access": return String(localized: "Access")
        case "survey_date", "check_date": return String(localized: "Surveyed")
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
