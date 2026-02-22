import Foundation

/// Info about the local Meshtastic device
struct MyNodeInfo {
    var nodeId: UInt32
    var shortName: String
    var longName: String
    var hardwareModel: String
    var firmwareVersion: String

    /// "!xxxxxxxx" format (Meshtastic standard address)
    var nodeIdHex: String {
        "!" + String(format: "%08x", nodeId)
    }
}
