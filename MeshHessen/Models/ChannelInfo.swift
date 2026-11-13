import Foundation

/// Represents a Meshtastic channel slot
struct ChannelInfo: Identifiable, Equatable {
    let id: Int             // channel index (0–7)
    var name: String
    var psk: String         // Base64
    var role: String        // "PRIMARY" / "SECONDARY"
    var uplinkEnabled: Bool
    var downlinkEnabled: Bool
    /// Firmware 2.8: channel uses AEAD (AES-CCM) instead of AES-CTR.
    var useAead: Bool = false
    /// Bits of position precision sent on this channel (`module_settings.position_precision`;
    /// 1…31 coarsen the position, 0 and 32 are treated as full precision). In memory only.
    var positionPrecision: Int = 0

    /// Display name including MQTT indicator
    var displayName: String {
        var suffix = ""
        if uplinkEnabled || downlinkEnabled { suffix = " 📡" }
        return name.isEmpty ? "Channel \(id)" : name + suffix
    }
}
