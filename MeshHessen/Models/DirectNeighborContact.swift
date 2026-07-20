import Foundation

/// One directly received RF contact, used for the neighbor-history map overlay.
struct DirectNeighborContact: Identifiable, Codable, Equatable, Sendable {
    var nodeId: UInt32
    var timestamp: Date
    var snr: Float?
    var rssi: Int32?
    var latitude: Double?
    var longitude: Double?

    var id: String {
        "\(nodeId)-\(timestamp.timeIntervalSince1970)"
    }
}

enum NeighborLineColorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case nodeColor
    case signalQuality
    case age

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nodeColor:     return String(localized: "Node color")
        case .signalQuality: return String(localized: "Signal quality")
        case .age:           return String(localized: "Age")
        }
    }
}
