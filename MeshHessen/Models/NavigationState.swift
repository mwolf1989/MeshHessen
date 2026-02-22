import Foundation

// MARK: - Navigation State (Router)

/// URL-based deep-link navigation state — modelled after official Meshtastic app.
/// Schema: `meshhessen:///messages?channelId=X`
///         `meshhessen:///nodes?nodenum=X`
///         `meshhessen:///map?nodenum=X`
///         `meshhessen:///settings/lora`
struct NavigationState: Hashable {

    // MARK: - Tab

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case messages
        case nodes
        case channels
        case map
        case settings
        case debug
        case info

        var id: String { rawValue }
    }

    var selectedTab: Tab = .messages

    // MARK: - Sub-states

    var messages: MessagesNavigationState?
    var nodeListSelectedNodeNum: UInt32?
    var map: MapNavigationState?
    var settings: SettingsNavigationState?
}

// MARK: - Messages Navigation

enum MessagesNavigationState: Hashable {
    case channels(channelId: Int? = nil, messageId: UInt32? = nil)
    case directMessages(userNum: UInt32? = nil, messageId: UInt32? = nil)
}

// MARK: - Map Navigation

enum MapNavigationState: Hashable {
    case selectedNode(UInt32)
    case waypoint(UInt32)
}

// MARK: - Settings Navigation

enum SettingsNavigationState: String, Hashable, CaseIterable, Identifiable {
    case about
    case appSettings
    case lora
    case channels
    case user
    case bluetooth
    case device
    case display
    case network
    case position
    case power
    case mqtt
    case serial
    case security
    case telemetry
    case debugLogs
    case appFiles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .about:       return String(localized: "About")
        case .appSettings: return String(localized: "App Settings")
        case .lora:        return String(localized: "LoRa")
        case .channels:    return String(localized: "Channels")
        case .user:        return String(localized: "User")
        case .bluetooth:   return String(localized: "Bluetooth")
        case .device:      return String(localized: "Device")
        case .display:     return String(localized: "Display")
        case .network:     return String(localized: "Network")
        case .position:    return String(localized: "Position")
        case .power:       return String(localized: "Power")
        case .mqtt:        return String(localized: "MQTT")
        case .serial:      return String(localized: "Serial")
        case .security:    return String(localized: "Security")
        case .telemetry:   return String(localized: "Telemetry")
        case .debugLogs:   return String(localized: "Debug Logs")
        case .appFiles:    return String(localized: "App Files")
        }
    }

    var systemImage: String {
        switch self {
        case .about:       return "info.circle"
        case .appSettings: return "gear"
        case .lora:        return "antenna.radiowaves.left.and.right"
        case .channels:    return "fibrechannel"
        case .user:        return "person"
        case .bluetooth:   return "bluetooth"
        case .device:      return "laptopcomputer"
        case .display:     return "display"
        case .network:     return "network"
        case .position:    return "location"
        case .power:       return "bolt"
        case .mqtt:        return "cloud"
        case .serial:      return "cable.connector"
        case .security:    return "lock.shield"
        case .telemetry:   return "chart.bar"
        case .debugLogs:   return "ladybug"
        case .appFiles:    return "folder"
        }
    }
}
