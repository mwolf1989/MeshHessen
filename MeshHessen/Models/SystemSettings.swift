import Foundation

// MARK: - Application

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case german = "de"
    case english = "en"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .system: return String(localized: "System language")
        case .german: return String(localized: "German")
        case .english: return String(localized: "English")
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .german: return "de"
        case .english: return "en"
        }
    }
}

enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .system: return String(localized: "System appearance")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

// MARK: - Retention

enum RetentionPeriod: Int, CaseIterable, Codable, Identifiable, Sendable {
    case unlimited = 0
    case days30 = 30
    case days90 = 90
    case days365 = 365

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .unlimited: return String(localized: "Unlimited")
        case .days30: return String(localized: "30 days")
        case .days90: return String(localized: "90 days")
        case .days365: return String(localized: "365 days")
        }
    }
}

enum NodeKeyMismatchPolicy: Int, CaseIterable, Codable, Identifiable, Sendable {
    case warn = 0
    case overwrite = 1
    case ask = 2

    var id: Int { rawValue }

    var localizedName: String {
        switch self {
        case .warn: return String(localized: "Warn")
        case .overwrite: return String(localized: "Overwrite")
        case .ask: return String(localized: "Ask")
        }
    }
}

// MARK: - Map

enum MapRenderMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case raster
    case vector

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .raster: return String(localized: "Raster")
        case .vector: return String(localized: "Vector")
        }
    }
}

enum MapMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case offline
    case meshHessen = "online-own"
    case custom = "online-custom"
    case publicOpenStreetMap = "online-osm"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .offline: return String(localized: "Offline")
        case .meshHessen: return String(localized: "Mesh Hessen server")
        case .custom: return String(localized: "Custom server")
        case .publicOpenStreetMap: return String(localized: "Public OpenStreetMap")
        }
    }
}

/// Styles shared by raster and vector map implementations.
/// Named differently from `MapView.MapStyle`, which represents the existing native Apple fallback.
enum MeshMapStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case osm
    case dark = "osmdark"
    case topography = "osmtopo"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .osm: return String(localized: "OpenStreetMap")
        case .dark: return String(localized: "Dark")
        case .topography: return String(localized: "Topographic")
        }
    }
}

enum MapOverlay: String, CaseIterable, Codable, Identifiable, Sendable {
    case emergency

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .emergency: return String(localized: "Fire and rescue")
        }
    }
}

// MARK: - Kiosk

struct KioskFeatureMask: OptionSet, Codable, Hashable, Identifiable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    var id: UInt16 { rawValue }

    static let nodes = Self(rawValue: 1 << 0)
    static let channels = Self(rawValue: 1 << 1)
    static let settings = Self(rawValue: 1 << 2)
    static let info = Self(rawValue: 1 << 3)
    static let tools = Self(rawValue: 1 << 4)
    static let debug = Self(rawValue: 1 << 5)
    static let nodeConfiguration = Self(rawValue: 1 << 6)
    static let remoteAdmin = Self(rawValue: 1 << 7)
    static let dashboard = Self(rawValue: 1 << 8)
    static let sos = Self(rawValue: 1 << 9)
    static let quickConfiguration = Self(rawValue: 1 << 10)

    static let allCases: [Self] = [
        .nodes,
        .channels,
        .settings,
        .info,
        .tools,
        .debug,
        .nodeConfiguration,
        .remoteAdmin,
        .dashboard,
        .sos,
        .quickConfiguration,
    ]

    static let all = Self(rawValue: allCases.reduce(0) { $0 | $1.rawValue })

    var localizedName: String {
        switch self {
        case .nodes: return String(localized: "Nodes tab")
        case .channels: return String(localized: "Channels tab")
        case .settings: return String(localized: "Settings")
        case .info: return String(localized: "Info tab")
        case .tools: return String(localized: "Tools tab")
        case .debug: return String(localized: "Debug tab")
        case .nodeConfiguration: return String(localized: "Node configuration")
        case .remoteAdmin: return String(localized: "Remote administration")
        case .dashboard: return String(localized: "Telemetry dashboard")
        case .sos: return String(localized: "SOS / alert bell")
        case .quickConfiguration: return String(localized: "Mesh Hessen quick configuration")
        default: return String(localized: "Unknown feature")
        }
    }
}

// MARK: - Connection persistence

extension ConnectionType {
    init?(settingsIdentifier: String) {
        switch settingsIdentifier.lowercased() {
        case "serial", "serial / usb": self = .serial
        case "bluetooth", "ble": self = .bluetooth
        case "tcp", "tcp / wifi": self = .tcp
        default: return nil
        }
    }

    var settingsIdentifier: String {
        switch self {
        case .serial: return "Serial"
        case .bluetooth: return "Bluetooth"
        case .tcp: return "Tcp"
        }
    }
}
