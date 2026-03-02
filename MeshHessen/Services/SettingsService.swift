import Foundation
import SwiftUI

/// Persistent settings backed by UserDefaults
@Observable
final class SettingsService {
    static let shared = SettingsService()

    private let defaults = UserDefaults.standard

    private init() {
        self.fontSizeStep = defaults.integer(forKey: "fontSizeStep")
    }

    // MARK: - General
    var stationName: String {
        get { defaults.string(forKey: "stationName") ?? "" }
        set {
            let oldValue = defaults.string(forKey: "stationName") ?? ""
            if oldValue != newValue {
                defaults.set(newValue, forKey: "stationName")
                AppLogger.shared.log("[Settings] stationName changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var showEncryptedMessages: Bool {
        get { defaults.object(forKey: "showEncryptedMessages") as? Bool ?? true }
        set {
            let oldValue = defaults.object(forKey: "showEncryptedMessages") as? Bool ?? true
            if oldValue != newValue {
                defaults.set(newValue, forKey: "showEncryptedMessages")
                AppLogger.shared.log("[Settings] showEncryptedMessages changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    /// Font size adjustment step: −3 (smallest) … 0 (default) … +3 (largest).
    var fontSizeStep: Int {
        didSet {
            let clamped = max(-3, min(3, fontSizeStep))
            if fontSizeStep != clamped { fontSizeStep = clamped }
            if defaults.integer(forKey: "fontSizeStep") != clamped {
                defaults.set(clamped, forKey: "fontSizeStep")
                AppLogger.shared.log("[Settings] fontSizeStep: \(clamped)", debug: true)
            }
        }
    }

    /// Maps `fontSizeStep` to the corresponding `DynamicTypeSize`.
    var dynamicTypeSize: DynamicTypeSize {
        switch fontSizeStep {
        case ..<(-2): return .xSmall
        case -2:      return .small
        case -1:      return .medium
        case 0:       return .large
        case 1:       return .xLarge
        case 2:       return .xxLarge
        default:      return .xxxLarge
        }
    }

    /// Scaled default body font for macOS, where `DynamicTypeSize` is often ignored.
    /// Base size 13 pt (macOS system body) ± 2 pt per step.
    var scaledBodyFont: Font {
        let baseSize: CGFloat = 13
        let pointSize = baseSize + CGFloat(fontSizeStep) * 2
        return .system(size: max(9, pointSize))
    }

    // MARK: - Connection
    var lastComPort: String {
        get { defaults.string(forKey: "lastComPort") ?? "" }
        set {
            let oldValue = defaults.string(forKey: "lastComPort") ?? ""
            if oldValue != newValue {
                defaults.set(newValue, forKey: "lastComPort")
                AppLogger.shared.log("[Settings] lastComPort changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var lastTcpHost: String {
        get { defaults.string(forKey: "lastTcpHost") ?? "192.168.1.1" }
        set {
            let oldValue = defaults.string(forKey: "lastTcpHost") ?? "192.168.1.1"
            if oldValue != newValue {
                defaults.set(newValue, forKey: "lastTcpHost")
                AppLogger.shared.log("[Settings] lastTcpHost changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var lastTcpPort: Int {
        get { defaults.integer(forKey: "lastTcpPort") == 0 ? 4403 : defaults.integer(forKey: "lastTcpPort") }
        set {
            let oldValue = defaults.integer(forKey: "lastTcpPort") == 0 ? 4403 : defaults.integer(forKey: "lastTcpPort")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "lastTcpPort")
                AppLogger.shared.log("[Settings] lastTcpPort changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    // MARK: - Map / GPS
    var myLatitude: Double {
        get {
            let v = defaults.double(forKey: "myLatitude")
            return v == 0 ? 50.9 : v   // default: central Hesse
        }
        set {
            let oldValue = defaults.double(forKey: "myLatitude")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "myLatitude")
                AppLogger.shared.log("[Settings] myLatitude changed: \(String(format: "%.4f", oldValue)) → \(String(format: "%.4f", newValue))", debug: true)
            }
        }
    }

    var myLongitude: Double {
        get {
            let v = defaults.double(forKey: "myLongitude")
            return v == 0 ? 9.5 : v   // default: central Hesse
        }
        set {
            let oldValue = defaults.double(forKey: "myLongitude")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "myLongitude")
                AppLogger.shared.log("[Settings] myLongitude changed: \(String(format: "%.4f", oldValue)) → \(String(format: "%.4f", newValue))", debug: true)
            }
        }
    }

    var hasExplicitOwnPosition: Bool {
        defaults.object(forKey: "myLatitude") != nil && defaults.object(forKey: "myLongitude") != nil
    }

    var mapSource: String {
        get { defaults.string(forKey: "mapSource") ?? "osm" }
        set {
            let oldValue = defaults.string(forKey: "mapSource") ?? "osm"
            if oldValue != newValue {
                defaults.set(newValue, forKey: "mapSource")
                AppLogger.shared.log("[Settings] mapSource changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }


    // MARK: - Notifications
    var alertBellSound: Bool {
        get { defaults.object(forKey: "alertBellSound") as? Bool ?? true }
        set {
            let oldValue = defaults.object(forKey: "alertBellSound") as? Bool ?? true
            if oldValue != newValue {
                defaults.set(newValue, forKey: "alertBellSound")
                AppLogger.shared.log("[Settings] alertBellSound changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    // MARK: - Debug flags
    var debugMessages: Bool {
        get { defaults.bool(forKey: "debugMessages") }
        set {
            let oldValue = defaults.bool(forKey: "debugMessages")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "debugMessages")
                AppLogger.shared.log("[Settings] debugMessages changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugSerial: Bool {
        get { defaults.bool(forKey: "debugSerial") }
        set {
            let oldValue = defaults.bool(forKey: "debugSerial")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "debugSerial")
                AppLogger.shared.log("[Settings] debugSerial changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugDevice: Bool {
        get { defaults.bool(forKey: "debugDevice") }
        set {
            let oldValue = defaults.bool(forKey: "debugDevice")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "debugDevice")
                AppLogger.shared.log("[Settings] debugDevice changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugBluetooth: Bool {
        get { defaults.bool(forKey: "debugBluetooth") }
        set {
            let oldValue = defaults.bool(forKey: "debugBluetooth")
            if oldValue != newValue {
                defaults.set(newValue, forKey: "debugBluetooth")
                AppLogger.shared.log("[Settings] debugBluetooth changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    // MARK: - Location Logging

    var locationLoggingEnabled: Bool {
        get { defaults.bool(forKey: "locationLoggingEnabled") }
        set {
            defaults.set(newValue, forKey: "locationLoggingEnabled")
            AppLogger.shared.log("[Settings] locationLoggingEnabled changed to \(newValue)", debug: true)
        }
    }

    // MARK: - Per-node color / note

    func colorHex(for nodeId: UInt32) -> String {
        let key = "nodeColor_\(String(format: "%08x", nodeId))"
        return defaults.string(forKey: key) ?? ""
    }

    func setColorHex(_ hex: String, for nodeId: UInt32) {
        let key = "nodeColor_\(String(format: "%08x", nodeId))"
        let oldValue = defaults.string(forKey: key) ?? ""
        if oldValue != hex {
            if hex.isEmpty {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(hex, forKey: key)
            }
            AppLogger.shared.log("[Settings] Color for node \(String(format: "%08x", nodeId)) changed: '\(oldValue)' → '\(hex)'", debug: true)
        }
    }

    func note(for nodeId: UInt32) -> String {
        let key = "nodeNote_\(String(format: "%08x", nodeId))"
        return defaults.string(forKey: key) ?? ""
    }

    func setNote(_ note: String, for nodeId: UInt32) {
        let key = "nodeNote_\(String(format: "%08x", nodeId))"
        let oldValue = defaults.string(forKey: key) ?? ""
        if oldValue != note {
            defaults.set(note, forKey: key)
            AppLogger.shared.log("[Settings] Note for node \(String(format: "%08x", nodeId)) changed: '\(oldValue)' → '\(note)'", debug: true)
        }
    }
}
