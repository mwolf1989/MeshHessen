import Foundation

/// Information packets that can be requested from a remote Meshtastic node.
enum NodeInfoRequestType: String, CaseIterable, Identifiable, Codable, Sendable {
    case userInfo
    case position
    case deviceMetrics
    case environmentMetrics
    case airQualityMetrics
    case powerMetrics
    case localStats
    case hostMetrics
    case paxCounter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userInfo:          return String(localized: "User information")
        case .position:          return String(localized: "Position")
        case .deviceMetrics:     return String(localized: "Device metrics")
        case .environmentMetrics:return String(localized: "Environment metrics")
        case .airQualityMetrics: return String(localized: "Air-quality metrics")
        case .powerMetrics:      return String(localized: "Power metrics")
        case .localStats:        return String(localized: "Local statistics")
        case .hostMetrics:       return String(localized: "Host metrics")
        case .paxCounter:        return String(localized: "PAX counter")
        }
    }

    var systemImage: String {
        switch self {
        case .userInfo:           return "person.text.rectangle"
        case .position:           return "location"
        case .deviceMetrics:      return "gauge.with.dots.needle.50percent"
        case .environmentMetrics: return "thermometer.medium"
        case .airQualityMetrics:  return "aqi.medium"
        case .powerMetrics:       return "bolt"
        case .localStats:         return "chart.bar"
        case .hostMetrics:        return "desktopcomputer"
        case .paxCounter:         return "person.2"
        }
    }
}
