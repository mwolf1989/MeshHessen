import Foundation

/// Info about the local Meshtastic device
struct MyNodeInfo {
    var nodeId: UInt32
    var shortName: String
    var longName: String
    var hardwareModel: String
    var firmwareVersion: String
    /// PlatformIO environment the firmware was built for (`MyNodeInfo.pio_env`), e.g. "heltec-v3".
    var pioEnv: String = ""
    /// Raw `HardwareModel` enum value (0 = unset).
    var hardwareModelRaw: Int = 0
    var hasWifi = false
    var hasBluetooth = false

    /// "!xxxxxxxx" format (Meshtastic standard address)
    var nodeIdHex: String {
        "!" + String(format: "%08x", nodeId)
    }
}
