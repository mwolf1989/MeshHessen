import Foundation

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
