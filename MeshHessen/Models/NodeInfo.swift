import Foundation

/// Persistent ordering choices for the sidebar node list.
enum NodeSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case snr
    case distance
    case battery
    case lastHeard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:      return String(localized: "Name")
        case .snr:       return String(localized: "Signal")
        case .distance:  return String(localized: "Distance")
        case .battery:   return String(localized: "Battery")
        case .lastHeard: return String(localized: "Last Heard")
        }
    }

    func sorted(_ nodes: [NodeInfo]) -> [NodeInfo] {
        nodes.sorted(by: areInIncreasingOrder)
    }

    private func areInIncreasingOrder(_ lhs: NodeInfo, _ rhs: NodeInfo) -> Bool {
        if lhs.isOwnNode != rhs.isOwnNode { return lhs.isOwnNode }
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

        switch self {
        case .snr where lhs.directSnr != rhs.directSnr:
            return (lhs.directSnr ?? -.infinity) > (rhs.directSnr ?? -.infinity)
        case .distance where lhs.distanceMeters != rhs.distanceMeters:
            if lhs.distanceMeters == 0 { return false }
            if rhs.distanceMeters == 0 { return true }
            return lhs.distanceMeters < rhs.distanceMeters
        case .battery where lhs.batteryLevel != rhs.batteryLevel:
            return lhs.batteryLevel > rhs.batteryLevel
        case .lastHeard where lhs.lastHeard != rhs.lastHeard:
            if lhs.lastHeard == 0 { return false }
            if rhs.lastHeard == 0 { return true }
            return lhs.lastHeard > rhs.lastHeard
        default:
            break
        }

        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison == .orderedSame {
            return lhs.id < rhs.id
        }
        return nameComparison == .orderedAscending
    }
}

/// Time ranges exposed by the Windows client's advanced node filter.
enum NodeAgeFilter: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case sixHours = 21_600
    case twelveHours = 43_200
    case oneDay = 86_400
    case sevenDays = 604_800
    case thirtyDays = 2_592_000
    case sixtyDays = 5_184_000
    case all = 0

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes:    return String(localized: "5 minutes")
        case .fifteenMinutes: return String(localized: "15 minutes")
        case .thirtyMinutes:  return String(localized: "30 minutes")
        case .oneHour:        return String(localized: "1 hour")
        case .sixHours:       return String(localized: "6 hours")
        case .twelveHours:    return String(localized: "12 hours")
        case .oneDay:         return String(localized: "1 day")
        case .sevenDays:      return String(localized: "7 days")
        case .thirtyDays:     return String(localized: "30 days")
        case .sixtyDays:      return String(localized: "60 days")
        case .all:            return String(localized: "All")
        }
    }

    func includes(lastHeard: Int32, now: Date = Date()) -> Bool {
        guard self != .all else { return true }
        guard lastHeard > 0 else { return false }
        return now.timeIntervalSince1970 - TimeInterval(lastHeard) <= TimeInterval(rawValue)
    }
}

/// Represents a node in the Meshtastic mesh network
@Observable
final class NodeInfo: Identifiable {
    let id: UInt32          // numeric node ID (= num)
    var nodeId: String      // "!xxxxxxxx" hex string
    var shortName: String
    var longName: String
    var name: String {      // display name (longName, shortName, or node ID fallback)
        didSet {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = Self.resolvedName(id: id, shortName: shortName, longName: longName)
            }
        }
    }

    // Telemetry (string for display)
    var distance: String = "-"
    var snr: String = "-"
    var rssi: String = "-"
    var battery: String = "-"
    var lastSeen: String = "-"

    // GPS
    var latitude: Double?
    var longitude: Double?
    var altitude: Int?
    var groundSpeed: UInt32 = 0
    var groundTrack: UInt32 = 0

    // User customization
    var colorHex: String = ""   // "#RRGGBB" or empty
    var note: String = ""
    var isPinned: Bool = false
    var isFavorite: Bool = false
    var isOwnNode: Bool = false
    var lastTracerouteHopCount: Int = 0

    // Device metadata
    var hardwareModel: String = ""
    var firmwareVersion: String = ""
    var role: String = ""
    var isInfrastructure: Bool = false

    // Raw values for calculations
    var lastHeard: Int32 = 0
    var snrFloat: Float = 0
    var rssiInt: Int32 = 0
    var batteryLevel: UInt32 = 0
    var voltage: Float = 0
    var channelUtilization: Float = 0
    var airUtilTx: Float = 0
    var distanceMeters: Double = 0

    var viaMqtt: Bool = false
    var publicKey: Data = Data()

    // Direct RF metadata. Relay and MQTT packets must not overwrite these values.
    var hopsAway: Int?
    var lastDirectHeard: Int32 = 0
    var directSnr: Float?
    var directRssi: Int32?

    // Latest environment / air-quality / host telemetry values.
    var temperature: Float?
    var relativeHumidity: Float?
    var barometricPressure: Float?
    var airQualityIndex: UInt32?
    var pm25: UInt32?
    var pm10: UInt32?
    var powerMetrics: [PowerChannelMetric] = []
    var localStats: NodeLocalStats?
    var hostMetrics: NodeHostMetrics?
    var healthMetrics: NodeHealthMetrics?
    var trafficStats: NodeTrafficStats?
    var paxMetrics: NodePaxMetrics?

    var paxCount: UInt32? {
        guard let paxMetrics else { return nil }
        return paxMetrics.wifi + paxMetrics.ble
    }

    init(id: UInt32, nodeId: String, shortName: String, longName: String) {
        self.id = id
        self.nodeId = nodeId
        self.shortName = shortName
        self.longName = longName
        self.name = Self.resolvedName(id: id, shortName: shortName, longName: longName)
    }

    /// Resolves the stable display name used when a node does not advertise a name.
    static func resolvedName(id: UInt32, shortName: String, longName: String) -> String {
        let trimmedLongName = longName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLongName.isEmpty { return trimmedLongName }

        let trimmedShortName = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedShortName.isEmpty { return trimmedShortName }

        return String(format: "!%08x", id)
    }

    /// NSColor / Color from colorHex, or nil if not set
    var color: String? {
        colorHex.isEmpty ? nil : colorHex
    }

    var hasPublicKey: Bool { !publicKey.isEmpty }

    var isDirectRF: Bool {
        hopsAway == 0 && !viaMqtt && lastDirectHeard > 0
    }

    var directSignalText: String? {
        guard isDirectRF else { return nil }
        if let directSnr { return String(format: "%.1f dB", directSnr) }
        if let directRssi { return "\(directRssi) dBm" }
        return nil
    }
}

struct PowerChannelMetric: Identifiable, Codable, Equatable, Sendable {
    let channel: Int
    var voltage: Float
    var current: Float

    var id: Int { channel }
}

struct NodeLocalStats: Codable, Equatable, Sendable {
    var uptimeSeconds: UInt32
    var channelUtilization: Float
    var airUtilTx: Float
    var packetsTx: UInt32
    var packetsRx: UInt32
    var packetsRxBad: UInt32
    var onlineNodes: UInt32
    var totalNodes: UInt32
    var duplicatePackets: UInt32
    var relayedPackets: UInt32
    var canceledRelays: UInt32
    var heapTotalBytes: UInt32
    var heapFreeBytes: UInt32
    var droppedTransmissions: UInt32
    var noiseFloor: Int32
}

struct NodeHostMetrics: Codable, Equatable, Sendable {
    var uptimeSeconds: UInt32
    var freeMemoryBytes: UInt64
    var diskFreeBytes: UInt64
    var load1: UInt32
    var load5: UInt32
    var load15: UInt32
    var userString: String
}

struct NodeHealthMetrics: Codable, Equatable, Sendable {
    var heartRateBPM: UInt32
    var oxygenSaturation: UInt32
    var temperature: Float
}

struct NodeTrafficStats: Codable, Equatable, Sendable {
    var packetsInspected: UInt32
    var positionDedupDrops: UInt32
    var nodeInfoCacheHits: UInt32
    var rateLimitDrops: UInt32
    var unknownPacketDrops: UInt32
    var hopExhaustedPackets: UInt32
    var routerHopsPreserved: UInt32
}

struct NodePaxMetrics: Codable, Equatable, Sendable {
    var wifi: UInt32
    var ble: UInt32
    var uptimeSeconds: UInt32
}
