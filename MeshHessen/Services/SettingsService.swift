import Foundation
import SwiftUI

/// Persistent settings backed by UserDefaults
@Observable
final class SettingsService {
    static let shared = SettingsService()

    private static let telemetryChartMetricsKey = "telemetryChartMetrics"
    private static let settingsSchemaVersion = 1

    private let defaults: UserDefaults

    private convenience init() {
        self.init(defaults: .standard)
    }

    /// Creates settings backed by the supplied defaults store.
    /// A separate suite keeps tests isolated from the app-wide singleton.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        Self.migrateLegacySettings(in: defaults)
        self.fontSizeStep = defaults.integer(forKey: "fontSizeStep")
        self.nodeSortOrder = NodeSortOrder(
            rawValue: defaults.string(forKey: "nodeSortOrder") ?? ""
        ) ?? .name
        self.telemetryChartMetrics = Self.loadTelemetryChartMetrics(from: defaults)
    }

    // MARK: - General

    var appLanguage: AppLanguage {
        get {
            access(keyPath: \.appLanguage)
            let rawValue = defaults.string(forKey: "appLanguage") ?? AppLanguage.german.rawValue
            return AppLanguage(rawValue: rawValue) ?? .german
        }
        set {
            withMutation(keyPath: \.appLanguage) {
                defaults.set(newValue.rawValue, forKey: "appLanguage")
            }
        }
    }

    var appearance: AppAppearance {
        get {
            access(keyPath: \.appearance)
            let rawValue = defaults.string(forKey: "appAppearance") ?? AppAppearance.system.rawValue
            return AppAppearance(rawValue: rawValue) ?? .system
        }
        set {
            withMutation(keyPath: \.appearance) {
                defaults.set(newValue.rawValue, forKey: "appAppearance")
            }
        }
    }

    var appLocale: Locale {
        guard let identifier = appLanguage.localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var stationName: String {
        get {
            access(keyPath: \.stationName)
            return defaults.string(forKey: "stationName") ?? ""
        }
        set {
            let oldValue = defaults.string(forKey: "stationName") ?? ""
            if oldValue != newValue {
                withMutation(keyPath: \.stationName) {
                    defaults.set(newValue, forKey: "stationName")
                }
                AppLogger.shared.log("[Settings] stationName changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var showEncryptedMessages: Bool {
        get {
            access(keyPath: \.showEncryptedMessages)
            return defaults.object(forKey: "showEncryptedMessages") as? Bool ?? true
        }
        set {
            let oldValue = defaults.object(forKey: "showEncryptedMessages") as? Bool ?? true
            if oldValue != newValue {
                withMutation(keyPath: \.showEncryptedMessages) {
                    defaults.set(newValue, forKey: "showEncryptedMessages")
                }
                AppLogger.shared.log("[Settings] showEncryptedMessages changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var messageHistoryEnabled: Bool {
        get {
            access(keyPath: \.messageHistoryEnabled)
            return defaults.object(forKey: "messageHistoryEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.messageHistoryEnabled) {
                defaults.set(newValue, forKey: "messageHistoryEnabled")
            }
        }
    }

    var messageRetention: RetentionPeriod {
        get {
            access(keyPath: \.messageRetention)
            guard defaults.object(forKey: "messageRetentionDays") != nil else { return .days90 }
            return RetentionPeriod(rawValue: defaults.integer(forKey: "messageRetentionDays")) ?? .days90
        }
        set {
            withMutation(keyPath: \.messageRetention) {
                defaults.set(newValue.rawValue, forKey: "messageRetentionDays")
            }
        }
    }

    /// Compatibility API for persistence services that operate on a day count.
    var messageRetentionDays: Int {
        get { messageRetention.rawValue }
        set { messageRetention = RetentionPeriod(rawValue: newValue) ?? .days90 }
    }

    var fancyNodeListEnabled: Bool {
        get {
            access(keyPath: \.fancyNodeListEnabled)
            return defaults.bool(forKey: "fancyNodeListEnabled")
        }
        set {
            withMutation(keyPath: \.fancyNodeListEnabled) {
                defaults.set(newValue, forKey: "fancyNodeListEnabled")
            }
        }
    }

    var colorfulNodeListEnabled: Bool {
        get {
            access(keyPath: \.colorfulNodeListEnabled)
            return defaults.object(forKey: "colorfulNodeListEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.colorfulNodeListEnabled) {
                defaults.set(newValue, forKey: "colorfulNodeListEnabled")
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

    /// Sidebar node ordering. Existing installations default to alphabetical order.
    var nodeSortOrder: NodeSortOrder {
        didSet {
            guard nodeSortOrder != oldValue else { return }
            defaults.set(nodeSortOrder.rawValue, forKey: "nodeSortOrder")
            AppLogger.shared.log("[Settings] nodeSortOrder: \(nodeSortOrder.rawValue)", debug: true)
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
        get {
            access(keyPath: \.lastComPort)
            return defaults.string(forKey: "lastComPort") ?? ""
        }
        set {
            let oldValue = defaults.string(forKey: "lastComPort") ?? ""
            if oldValue != newValue {
                withMutation(keyPath: \.lastComPort) {
                    defaults.set(newValue, forKey: "lastComPort")
                }
                AppLogger.shared.log("[Settings] lastComPort changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var lastTcpHost: String {
        get {
            access(keyPath: \.lastTcpHost)
            return defaults.string(forKey: "lastTcpHost") ?? "192.168.1.1"
        }
        set {
            let oldValue = defaults.string(forKey: "lastTcpHost") ?? "192.168.1.1"
            if oldValue != newValue {
                withMutation(keyPath: \.lastTcpHost) {
                    defaults.set(newValue, forKey: "lastTcpHost")
                }
                AppLogger.shared.log("[Settings] lastTcpHost changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var lastTcpPort: Int {
        get {
            access(keyPath: \.lastTcpPort)
            guard defaults.object(forKey: "lastTcpPort") != nil else { return 4403 }
            return max(1, min(65_535, defaults.integer(forKey: "lastTcpPort")))
        }
        set {
            let clamped = max(1, min(65_535, newValue))
            let oldValue = lastTcpPort
            if oldValue != clamped {
                withMutation(keyPath: \.lastTcpPort) {
                    defaults.set(clamped, forKey: "lastTcpPort")
                }
                AppLogger.shared.log("[Settings] lastTcpPort changed: \(oldValue) → \(clamped)", debug: true)
            }
        }
    }

    var lastConnectionType: ConnectionType {
        get {
            access(keyPath: \.lastConnectionType)
            let rawValue = defaults.string(forKey: "lastConnectionType") ?? "Serial"
            return ConnectionType(settingsIdentifier: rawValue) ?? .serial
        }
        set {
            withMutation(keyPath: \.lastConnectionType) {
                defaults.set(newValue.settingsIdentifier, forKey: "lastConnectionType")
            }
        }
    }

    /// UUID of the last CoreBluetooth peripheral, used for reliable reconnects.
    var lastBluetoothDeviceIdentifier: String {
        get {
            access(keyPath: \.lastBluetoothDeviceIdentifier)
            return defaults.string(forKey: "lastBluetoothDeviceIdentifier") ?? ""
        }
        set {
            withMutation(keyPath: \.lastBluetoothDeviceIdentifier) {
                defaults.set(newValue, forKey: "lastBluetoothDeviceIdentifier")
            }
        }
    }

    /// Human-readable name of the last CoreBluetooth peripheral.
    var lastBluetoothDeviceName: String {
        get {
            access(keyPath: \.lastBluetoothDeviceName)
            return defaults.string(forKey: "lastBluetoothDeviceName") ?? ""
        }
        set {
            withMutation(keyPath: \.lastBluetoothDeviceName) {
                defaults.set(newValue, forKey: "lastBluetoothDeviceName")
            }
        }
    }

    /// Compatibility alias for Windows' `LastBtDevice` setting.
    var lastBtDevice: String {
        get { lastBluetoothDeviceName }
        set { lastBluetoothDeviceName = newValue }
    }

    var remoteAdminTimeoutSeconds: Int {
        get {
            access(keyPath: \.remoteAdminTimeoutSeconds)
            guard defaults.object(forKey: "remoteAdminTimeoutSeconds") != nil else { return 30 }
            return max(5, min(120, defaults.integer(forKey: "remoteAdminTimeoutSeconds")))
        }
        set {
            withMutation(keyPath: \.remoteAdminTimeoutSeconds) {
                defaults.set(max(5, min(120, newValue)), forKey: "remoteAdminTimeoutSeconds")
            }
        }
    }

    var virtualNodeEnabled: Bool {
        get {
            access(keyPath: \.virtualNodeEnabled)
            return defaults.bool(forKey: "virtualNodeEnabled")
        }
        set {
            withMutation(keyPath: \.virtualNodeEnabled) {
                defaults.set(newValue, forKey: "virtualNodeEnabled")
            }
        }
    }

    var virtualNodePort: Int {
        get {
            access(keyPath: \.virtualNodePort)
            guard defaults.object(forKey: "virtualNodePort") != nil else { return 4404 }
            return max(1, min(65_535, defaults.integer(forKey: "virtualNodePort")))
        }
        set {
            withMutation(keyPath: \.virtualNodePort) {
                defaults.set(max(1, min(65_535, newValue)), forKey: "virtualNodePort")
            }
        }
    }

    var virtualNodeBlockAdmin: Bool {
        get {
            access(keyPath: \.virtualNodeBlockAdmin)
            return defaults.bool(forKey: "virtualNodeBlockAdmin")
        }
        set {
            withMutation(keyPath: \.virtualNodeBlockAdmin) {
                defaults.set(newValue, forKey: "virtualNodeBlockAdmin")
            }
        }
    }

    // MARK: - Map / GPS
    var myLatitude: Double {
        get {
            access(keyPath: \.myLatitude)
            guard defaults.object(forKey: "myLatitude") != nil else { return 50.9 }
            return defaults.double(forKey: "myLatitude")
        }
        set {
            let oldValue = defaults.double(forKey: "myLatitude")
            if oldValue != newValue {
                withMutation(keyPath: \.myLatitude) {
                    defaults.set(newValue, forKey: "myLatitude")
                }
                AppLogger.shared.log("[Settings] myLatitude changed: \(String(format: "%.4f", oldValue)) → \(String(format: "%.4f", newValue))", debug: true)
            }
        }
    }

    var myLongitude: Double {
        get {
            access(keyPath: \.myLongitude)
            guard defaults.object(forKey: "myLongitude") != nil else { return 9.5 }
            return defaults.double(forKey: "myLongitude")
        }
        set {
            let oldValue = defaults.double(forKey: "myLongitude")
            if oldValue != newValue {
                withMutation(keyPath: \.myLongitude) {
                    defaults.set(newValue, forKey: "myLongitude")
                }
                AppLogger.shared.log("[Settings] myLongitude changed: \(String(format: "%.4f", oldValue)) → \(String(format: "%.4f", newValue))", debug: true)
            }
        }
    }

    var hasExplicitOwnPosition: Bool {
        defaults.object(forKey: "myLatitude") != nil && defaults.object(forKey: "myLongitude") != nil
    }

    var mapSource: String {
        get {
            access(keyPath: \.mapSource)
            return defaults.string(forKey: "mapSource") ?? "osm"
        }
        set {
            let oldValue = defaults.string(forKey: "mapSource") ?? "osm"
            if oldValue != newValue {
                withMutation(keyPath: \.mapSource) {
                    defaults.set(newValue, forKey: "mapSource")
                }
                AppLogger.shared.log("[Settings] mapSource changed: '\(oldValue)' → '\(newValue)'", debug: true)
            }
        }
    }

    var mapRenderMode: MapRenderMode {
        get {
            access(keyPath: \.mapRenderMode)
            guard mapMode != .publicOpenStreetMap else { return .raster }
            let rawValue = defaults.string(forKey: "mapRenderMode") ?? MapRenderMode.raster.rawValue
            return MapRenderMode(rawValue: rawValue) ?? .raster
        }
        set {
            let effectiveValue: MapRenderMode = mapMode == .publicOpenStreetMap ? .raster : newValue
            withMutation(keyPath: \.mapRenderMode) {
                defaults.set(effectiveValue.rawValue, forKey: "mapRenderMode")
            }
        }
    }

    var mapMode: MapMode {
        get {
            access(keyPath: \.mapMode)
            let rawValue = defaults.string(forKey: "mapMode") ?? MapMode.offline.rawValue
            return MapMode(rawValue: rawValue) ?? .offline
        }
        set {
            withMutation(keyPath: \.mapMode) {
                defaults.set(newValue.rawValue, forKey: "mapMode")
            }
            guard newValue == .publicOpenStreetMap else { return }
            withMutation(keyPath: \.mapRenderMode) {
                defaults.set(MapRenderMode.raster.rawValue, forKey: "mapRenderMode")
            }
            withMutation(keyPath: \.meshMapStyle) {
                defaults.set(MeshMapStyle.osm.rawValue, forKey: "meshMapStyle")
            }
        }
    }

    var meshMapStyle: MeshMapStyle {
        get {
            access(keyPath: \.meshMapStyle)
            guard mapMode != .publicOpenStreetMap else { return .osm }
            let rawValue = defaults.string(forKey: "meshMapStyle") ?? MeshMapStyle.osm.rawValue
            return MeshMapStyle(rawValue: rawValue) ?? .osm
        }
        set {
            let effectiveValue: MeshMapStyle = mapMode == .publicOpenStreetMap ? .osm : newValue
            withMutation(keyPath: \.meshMapStyle) {
                defaults.set(effectiveValue.rawValue, forKey: "meshMapStyle")
            }
        }
    }

    var osmTileURL: String {
        get {
            access(keyPath: \.osmTileURL)
            return defaults.string(forKey: "osmTileURL")
                ?? "https://tile.meshhessenclient.de/osm/{z}/{x}/{y}.png"
        }
        set {
            withMutation(keyPath: \.osmTileURL) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "osmTileURL")
            }
        }
    }

    var topographicTileURL: String {
        get {
            access(keyPath: \.topographicTileURL)
            return defaults.string(forKey: "topographicTileURL")
                ?? "https://tile.meshhessenclient.de/opentopo/{z}/{x}/{y}.png"
        }
        set {
            withMutation(keyPath: \.topographicTileURL) {
                defaults.set(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: "topographicTileURL"
                )
            }
        }
    }

    var darkTileURL: String {
        get {
            access(keyPath: \.darkTileURL)
            return defaults.string(forKey: "darkTileURL")
                ?? "https://tile.meshhessenclient.de/dark/{z}/{x}/{y}.png"
        }
        set {
            withMutation(keyPath: \.darkTileURL) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "darkTileURL")
            }
        }
    }

    var publicOSMTileURL: String {
        get {
            access(keyPath: \.publicOSMTileURL)
            return defaults.string(forKey: "publicOSMTileURL")
                ?? "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        }
        set {
            withMutation(keyPath: \.publicOSMTileURL) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "publicOSMTileURL")
            }
        }
    }

    var vectorStyleOSMURL: String {
        get {
            access(keyPath: \.vectorStyleOSMURL)
            return defaults.string(forKey: "vectorStyleOSMURL")
                ?? "https://vectortile.meshhessenclient.de/styles/osm.json"
        }
        set {
            withMutation(keyPath: \.vectorStyleOSMURL) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vectorStyleOSMURL")
            }
        }
    }

    var vectorStyleTopographicURL: String {
        get {
            access(keyPath: \.vectorStyleTopographicURL)
            return defaults.string(forKey: "vectorStyleTopographicURL")
                ?? "https://vectortile.meshhessenclient.de/styles/opentopo.json"
        }
        set {
            withMutation(keyPath: \.vectorStyleTopographicURL) {
                defaults.set(
                    newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: "vectorStyleTopographicURL"
                )
            }
        }
    }

    var vectorStyleDarkURL: String {
        get {
            access(keyPath: \.vectorStyleDarkURL)
            return defaults.string(forKey: "vectorStyleDarkURL")
                ?? "https://vectortile.meshhessenclient.de/styles/dark.json"
        }
        set {
            withMutation(keyPath: \.vectorStyleDarkURL) {
                defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vectorStyleDarkURL")
            }
        }
    }

    var mapOverlays: Set<MapOverlay> {
        get {
            access(keyPath: \.mapOverlays)
            let rawValues = defaults.stringArray(forKey: "mapOverlays") ?? []
            return Set(rawValues.compactMap(MapOverlay.init(rawValue:)))
        }
        set {
            withMutation(keyPath: \.mapOverlays) {
                defaults.set(newValue.map(\.rawValue).sorted(), forKey: "mapOverlays")
            }
        }
    }

    var positionHistoryHours: Int {
        get {
            access(keyPath: \.positionHistoryHours)
            guard defaults.object(forKey: "positionHistoryHours") != nil else { return 24 }
            return max(0, defaults.integer(forKey: "positionHistoryHours"))
        }
        set {
            withMutation(keyPath: \.positionHistoryHours) {
                defaults.set(max(0, newValue), forKey: "positionHistoryHours")
            }
        }
    }


    // MARK: - Notifications
    var alertBellSound: Bool {
        get {
            access(keyPath: \.alertBellSound)
            return defaults.object(forKey: "alertBellSound") as? Bool ?? true
        }
        set {
            let oldValue = defaults.object(forKey: "alertBellSound") as? Bool ?? true
            if oldValue != newValue {
                withMutation(keyPath: \.alertBellSound) {
                    defaults.set(newValue, forKey: "alertBellSound")
                }
                AppLogger.shared.log("[Settings] alertBellSound changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    // MARK: - Debug flags
    var debugMessages: Bool {
        get {
            access(keyPath: \.debugMessages)
            return defaults.bool(forKey: "debugMessages")
        }
        set {
            let oldValue = defaults.bool(forKey: "debugMessages")
            if oldValue != newValue {
                withMutation(keyPath: \.debugMessages) {
                    defaults.set(newValue, forKey: "debugMessages")
                }
                AppLogger.shared.log("[Settings] debugMessages changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugSerial: Bool {
        get {
            access(keyPath: \.debugSerial)
            return defaults.bool(forKey: "debugSerial")
        }
        set {
            let oldValue = defaults.bool(forKey: "debugSerial")
            if oldValue != newValue {
                withMutation(keyPath: \.debugSerial) {
                    defaults.set(newValue, forKey: "debugSerial")
                }
                AppLogger.shared.log("[Settings] debugSerial changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugDevice: Bool {
        get {
            access(keyPath: \.debugDevice)
            return defaults.bool(forKey: "debugDevice")
        }
        set {
            let oldValue = defaults.bool(forKey: "debugDevice")
            if oldValue != newValue {
                withMutation(keyPath: \.debugDevice) {
                    defaults.set(newValue, forKey: "debugDevice")
                }
                AppLogger.shared.log("[Settings] debugDevice changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    var debugBluetooth: Bool {
        get {
            access(keyPath: \.debugBluetooth)
            return defaults.bool(forKey: "debugBluetooth")
        }
        set {
            let oldValue = defaults.bool(forKey: "debugBluetooth")
            if oldValue != newValue {
                withMutation(keyPath: \.debugBluetooth) {
                    defaults.set(newValue, forKey: "debugBluetooth")
                }
                AppLogger.shared.log("[Settings] debugBluetooth changed: \(oldValue) → \(newValue)", debug: true)
            }
        }
    }

    // MARK: - Location Logging

    var locationLoggingEnabled: Bool {
        get {
            access(keyPath: \.locationLoggingEnabled)
            return defaults.bool(forKey: "locationLoggingEnabled")
        }
        set {
            withMutation(keyPath: \.locationLoggingEnabled) {
                defaults.set(newValue, forKey: "locationLoggingEnabled")
            }
            AppLogger.shared.log("[Settings] locationLoggingEnabled changed to \(newValue)", debug: true)
        }
    }

    var autoTimeSyncOnConnect: Bool {
        get {
            access(keyPath: \.autoTimeSyncOnConnect)
            return defaults.object(forKey: "autoTimeSyncOnConnect") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoTimeSyncOnConnect) {
                defaults.set(newValue, forKey: "autoTimeSyncOnConnect")
            }
        }
    }

    /// Drift threshold in seconds. Zero disables drift correction.
    var timeSyncDriftThresholdSeconds: Int {
        get {
            access(keyPath: \.timeSyncDriftThresholdSeconds)
            guard defaults.object(forKey: "timeSyncDriftThresholdSeconds") != nil else { return 300 }
            let value = defaults.integer(forKey: "timeSyncDriftThresholdSeconds")
            return value == 0 ? 0 : max(60, min(86_400, value))
        }
        set {
            let value = newValue == 0 ? 0 : max(60, min(86_400, newValue))
            withMutation(keyPath: \.timeSyncDriftThresholdSeconds) {
                defaults.set(value, forKey: "timeSyncDriftThresholdSeconds")
            }
        }
    }

    // MARK: - Node Key / PKI

    enum KeyMismatchAction: Int, CaseIterable, Identifiable, Sendable {
        case warn = 0
        case overwrite = 1

        var id: Int { rawValue }

        var localizedName: String {
            switch self {
            case .warn: return String(localized: "Warn")
            case .overwrite: return String(localized: "Overwrite")
            }
        }
    }

    var nodeKeyMismatchAction: KeyMismatchAction {
        get {
            guard defaults.object(forKey: "nodeKeyMismatchAction") != nil else { return .overwrite }
            let rawValue = defaults.integer(forKey: "nodeKeyMismatchAction")
            // Until the interactive prompt is supplied by the protocol layer, "ask" fails safe as "warn".
            if rawValue == NodeKeyMismatchPolicy.ask.rawValue { return .warn }
            return KeyMismatchAction(rawValue: rawValue) ?? .overwrite
        }
        set { defaults.set(newValue.rawValue, forKey: "nodeKeyMismatchAction") }
    }

    /// Full Windows-compatible policy. The legacy two-case API remains for `NodeKeyService`.
    var nodeKeyMismatchPolicy: NodeKeyMismatchPolicy {
        get {
            access(keyPath: \.nodeKeyMismatchPolicy)
            guard defaults.object(forKey: "nodeKeyMismatchAction") != nil else { return .overwrite }
            return NodeKeyMismatchPolicy(rawValue: defaults.integer(forKey: "nodeKeyMismatchAction")) ?? .overwrite
        }
        set {
            withMutation(keyPath: \.nodeKeyMismatchPolicy) {
                defaults.set(newValue.rawValue, forKey: "nodeKeyMismatchAction")
            }
        }
    }

    // MARK: - Telemetry

    var telemetryRetentionDays: Int {
        get {
            access(keyPath: \.telemetryRetentionDays)
            guard defaults.object(forKey: "telemetryRetentionDays") != nil else { return 90 }
            let value = defaults.integer(forKey: "telemetryRetentionDays")
            return RetentionPeriod(rawValue: value)?.rawValue ?? 90
        }
        set {
            withMutation(keyPath: \.telemetryRetentionDays) {
                defaults.set(
                    RetentionPeriod(rawValue: newValue)?.rawValue ?? 90,
                    forKey: "telemetryRetentionDays"
                )
            }
        }
    }

    var telemetryRetention: RetentionPeriod {
        get { RetentionPeriod(rawValue: telemetryRetentionDays) ?? .days90 }
        set { telemetryRetentionDays = newValue.rawValue }
    }

    var signalAnalysisWindowHours: Int {
        get {
            access(keyPath: \.signalAnalysisWindowHours)
            guard defaults.object(forKey: "signalAnalysisWindowHours") != nil else { return 6 }
            return max(1, min(168, defaults.integer(forKey: "signalAnalysisWindowHours")))
        }
        set {
            withMutation(keyPath: \.signalAnalysisWindowHours) {
                defaults.set(max(1, min(168, newValue)), forKey: "signalAnalysisWindowHours")
            }
        }
    }

    var antennaAnalysisWindowDays: Int {
        get {
            access(keyPath: \.antennaAnalysisWindowDays)
            guard defaults.object(forKey: "antennaAnalysisWindowDays") != nil else { return 7 }
            return max(1, min(365, defaults.integer(forKey: "antennaAnalysisWindowDays")))
        }
        set {
            withMutation(keyPath: \.antennaAnalysisWindowDays) {
                defaults.set(max(1, min(365, newValue)), forKey: "antennaAnalysisWindowDays")
            }
        }
    }

    /// Metrics selected in telemetry charts, shared across nodes and app launches.
    var telemetryChartMetrics: Set<TelemetryMetric> {
        didSet {
            guard telemetryChartMetrics != oldValue else { return }
            let rawValues = telemetryChartMetrics.map(\.rawValue).sorted()
            defaults.set(rawValues, forKey: Self.telemetryChartMetricsKey)
            AppLogger.shared.log(
                "[Settings] telemetryChartMetrics: \(rawValues.joined(separator: ", "))",
                debug: true
            )
        }
    }

    private static func loadTelemetryChartMetrics(from defaults: UserDefaults) -> Set<TelemetryMetric> {
        guard let rawValues = defaults.stringArray(forKey: telemetryChartMetricsKey) else {
            return [.snr]
        }

        // An empty array is a deliberate choice: the chart shows its metric picker empty.
        guard !rawValues.isEmpty else { return [] }

        let metrics = Set(rawValues.compactMap(TelemetryMetric.init(rawValue:)))
        return metrics.isEmpty ? [.snr] : metrics
    }

    // MARK: - Kiosk / Training

    var kioskModeEnabled: Bool {
        get {
            access(keyPath: \.kioskModeEnabled)
            return defaults.bool(forKey: "kioskModeEnabled")
        }
        set {
            withMutation(keyPath: \.kioskModeEnabled) {
                defaults.set(newValue, forKey: "kioskModeEnabled")
            }
        }
    }

    var kioskLockedFeatures: KioskFeatureMask {
        get {
            access(keyPath: \.kioskLockedFeatures)
            let value = defaults.object(forKey: "kioskLockedFeaturesMask") as? NSNumber
            return KioskFeatureMask(rawValue: value?.uint16Value ?? 0)
        }
        set {
            withMutation(keyPath: \.kioskLockedFeatures) {
                defaults.set(Int(newValue.rawValue), forKey: "kioskLockedFeaturesMask")
            }
        }
    }

    // MARK: - Per-node station name

    func stationName(for nodeId: UInt32) -> String {
        defaults.string(forKey: nodeSettingKey(prefix: "nodeStationName", nodeId: nodeId)) ?? ""
    }

    func setStationName(_ stationName: String, for nodeId: UInt32) {
        let key = nodeSettingKey(prefix: "nodeStationName", nodeId: nodeId)
        let trimmedName = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmedName, forKey: key)
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

    // MARK: - Migration

    private static func migrateLegacySettings(in defaults: UserDefaults) {
        let version = defaults.integer(forKey: "settingsSchemaVersion")
        guard version < settingsSchemaVersion else { return }

        if defaults.object(forKey: "appLanguage") == nil {
            let legacyValue = defaults.string(forKey: "language")
            defaults.set(AppLanguage(rawValue: legacyValue ?? "")?.rawValue ?? AppLanguage.german.rawValue,
                         forKey: "appLanguage")
        }

        if defaults.object(forKey: "appAppearance") == nil,
           defaults.object(forKey: "darkMode") != nil {
            defaults.set(
                defaults.bool(forKey: "darkMode") ? AppAppearance.dark.rawValue : AppAppearance.light.rawValue,
                forKey: "appAppearance"
            )
        }

        if defaults.object(forKey: "meshMapStyle") == nil {
            let legacySource = defaults.string(forKey: "mapSource")?.lowercased()
            let style: MeshMapStyle
            switch legacySource {
            case "dark", "osmdark": style = .dark
            case "topography", "opentopo", "osmtopo": style = .topography
            default: style = .osm
            }
            defaults.set(style.rawValue, forKey: "meshMapStyle")
        }

        if defaults.object(forKey: "lastBluetoothDeviceName") == nil,
           let legacyDevice = defaults.string(forKey: "lastBtDevice") {
            defaults.set(legacyDevice, forKey: "lastBluetoothDeviceName")
        }

        if defaults.object(forKey: "messageHistoryEnabled") == nil,
           defaults.object(forKey: "enableMessageDb") != nil {
            defaults.set(defaults.bool(forKey: "enableMessageDb"), forKey: "messageHistoryEnabled")
        }

        if defaults.object(forKey: "messageRetentionDays") == nil,
           defaults.object(forKey: "messageDbRetentionDays") != nil {
            defaults.set(defaults.integer(forKey: "messageDbRetentionDays"), forKey: "messageRetentionDays")
        }

        defaults.set(settingsSchemaVersion, forKey: "settingsSchemaVersion")
    }

    private func nodeSettingKey(prefix: String, nodeId: UInt32) -> String {
        "\(prefix)_\(String(format: "%08x", nodeId))"
    }
}
