import Foundation

/// Persistent ordering choices for the sidebar node list.
enum NodeSortOrder: String, CaseIterable, Identifiable {
    case name
    case lastHeard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:      return String(localized: "Name")
        case .lastHeard: return String(localized: "Last Heard")
        }
    }

    func sorted(_ nodes: [NodeInfo]) -> [NodeInfo] {
        nodes.sorted(by: areInIncreasingOrder)
    }

    private func areInIncreasingOrder(_ lhs: NodeInfo, _ rhs: NodeInfo) -> Bool {
        if self == .lastHeard, lhs.lastHeard != rhs.lastHeard {
            if lhs.lastHeard == 0 { return false }
            if rhs.lastHeard == 0 { return true }
            return lhs.lastHeard > rhs.lastHeard
        }

        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison == .orderedSame {
            return lhs.id < rhs.id
        }
        return nameComparison == .orderedAscending
    }
}

/// Represents a node in the Meshtastic mesh network
@Observable
final class NodeInfo: Identifiable {
    let id: UInt32          // numeric node ID (= num)
    var nodeId: String      // "!xxxxxxxx" hex string
    var shortName: String
    var longName: String
    var name: String        // display name (longName or shortName fallback)

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

    // User customization
    var colorHex: String = ""   // "#RRGGBB" or empty
    var note: String = ""
    var isPinned: Bool = false
    var lastTracerouteHopCount: Int = 0

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

    init(id: UInt32, nodeId: String, shortName: String, longName: String) {
        self.id = id
        self.nodeId = nodeId
        self.shortName = shortName
        self.longName = longName
        self.name = longName.isEmpty ? shortName : longName
    }

    /// NSColor / Color from colorHex, or nil if not set
    var color: String? {
        colorHex.isEmpty ? nil : colorHex
    }
}
