import Foundation

/// A waypoint distributed through the Meshtastic waypoint port.
struct MeshWaypoint: Identifiable, Codable, Equatable, Sendable {
    var id: UInt32
    var latitude: Double
    var longitude: Double
    var name: String
    var detail: String
    var icon: UInt32
    var expiration: Date?
    var lockedTo: UInt32
    var sourceNodeId: UInt32
    var channelIndex: UInt32
    var receivedAt: Date

    var isExpired: Bool {
        guard let expiration else { return false }
        return expiration <= Date()
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? String(localized: "Waypoint") : trimmedName
    }
}
