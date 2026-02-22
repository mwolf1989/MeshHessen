import Foundation

/// Persistent settings backed by UserDefaults
@Observable
final class SettingsService {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard

    // MARK: - General
    var stationName: String {
        get { defaults.string(forKey: "stationName") ?? "" }
        set { defaults.set(newValue, forKey: "stationName") }
    }

    var showEncryptedMessages: Bool {
        get { defaults.object(forKey: "showEncryptedMessages") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showEncryptedMessages") }
    }

    // MARK: - Connection
    var lastComPort: String {
        get { defaults.string(forKey: "lastComPort") ?? "" }
        set { defaults.set(newValue, forKey: "lastComPort") }
    }

    var lastTcpHost: String {
        get { defaults.string(forKey: "lastTcpHost") ?? "192.168.1.1" }
        set { defaults.set(newValue, forKey: "lastTcpHost") }
    }

    var lastTcpPort: Int {
        get { defaults.integer(forKey: "lastTcpPort") == 0 ? 4403 : defaults.integer(forKey: "lastTcpPort") }
        set { defaults.set(newValue, forKey: "lastTcpPort") }
    }

    // MARK: - Map / GPS
    var myLatitude: Double {
        get {
            let v = defaults.double(forKey: "myLatitude")
            return v == 0 ? 50.9 : v   // default: central Hesse
        }
        set { defaults.set(newValue, forKey: "myLatitude") }
    }

    var myLongitude: Double {
        get {
            let v = defaults.double(forKey: "myLongitude")
            return v == 0 ? 9.5 : v   // default: central Hesse
        }
        set { defaults.set(newValue, forKey: "myLongitude") }
    }

    var mapSource: String {
        get { defaults.string(forKey: "mapSource") ?? "osm" }
        set { defaults.set(newValue, forKey: "mapSource") }
    }

    var osmTileUrl: String {
        get { defaults.string(forKey: "osmTileUrl") ?? "https://tile.schwarzes-seelenreich.de/osm/{z}/{x}/{y}.png" }
        set { defaults.set(newValue, forKey: "osmTileUrl") }
    }

    var osmTopoTileUrl: String {
        get { defaults.string(forKey: "osmTopoTileUrl") ?? "https://tile.schwarzes-seelenreich.de/opentopo/{z}/{x}/{y}.png" }
        set { defaults.set(newValue, forKey: "osmTopoTileUrl") }
    }

    var osmDarkTileUrl: String {
        get { defaults.string(forKey: "osmDarkTileUrl") ?? "https://tile.schwarzes-seelenreich.de/dark/{z}/{x}/{y}.png" }
        set { defaults.set(newValue, forKey: "osmDarkTileUrl") }
    }

    var activeTileUrl: String {
        switch mapSource {
        case "osmtopo": return osmTopoTileUrl
        case "osmdark": return osmDarkTileUrl
        default:        return osmTileUrl
        }
    }

    // MARK: - Notifications
    var alertBellSound: Bool {
        get { defaults.object(forKey: "alertBellSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alertBellSound") }
    }

    // MARK: - Debug flags
    var debugMessages: Bool {
        get { defaults.bool(forKey: "debugMessages") }
        set { defaults.set(newValue, forKey: "debugMessages") }
    }

    var debugSerial: Bool {
        get { defaults.bool(forKey: "debugSerial") }
        set { defaults.set(newValue, forKey: "debugSerial") }
    }

    var debugDevice: Bool {
        get { defaults.bool(forKey: "debugDevice") }
        set { defaults.set(newValue, forKey: "debugDevice") }
    }

    var debugBluetooth: Bool {
        get { defaults.bool(forKey: "debugBluetooth") }
        set { defaults.set(newValue, forKey: "debugBluetooth") }
    }

    // MARK: - Per-node color / note

    func colorHex(for nodeId: UInt32) -> String {
        let key = "nodeColor_\(String(format: "%08x", nodeId))"
        return defaults.string(forKey: key) ?? ""
    }

    func setColorHex(_ hex: String, for nodeId: UInt32) {
        let key = "nodeColor_\(String(format: "%08x", nodeId))"
        if hex.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(hex, forKey: key)
        }
    }

    func note(for nodeId: UInt32) -> String {
        let key = "nodeNote_\(String(format: "%08x", nodeId))"
        return defaults.string(forKey: key) ?? ""
    }

    func setNote(_ note: String, for nodeId: UInt32) {
        let key = "nodeNote_\(String(format: "%08x", nodeId))"
        defaults.set(note, forKey: key)
    }
}
