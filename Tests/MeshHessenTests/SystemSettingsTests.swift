import Foundation
import Observation
import Testing

@testable import MeshHessen

@Suite("System Settings")
struct SystemSettingsTests {
    @Test("Fresh settings use the Windows parity defaults")
    func parityDefaults() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }

        let settings = SettingsService(defaults: store.defaults)

        #expect(settings.appLanguage == .german)
        #expect(settings.appearance == .system)
        #expect(settings.appLocale.identifier.hasPrefix("de"))
        #expect(settings.preferredColorScheme == nil)
        #expect(settings.messageHistoryEnabled)
        #expect(settings.messageRetention == .days90)
        #expect(settings.telemetryRetention == .days90)
        #expect(settings.nodeKeyMismatchPolicy == .overwrite)
        #expect(settings.signalAnalysisWindowHours == 6)
        #expect(settings.antennaAnalysisWindowDays == 7)
        #expect(settings.positionHistoryHours == 24)
        #expect(settings.autoTimeSyncOnConnect)
        #expect(settings.timeSyncDriftThresholdSeconds == 300)
        #expect(settings.mapMode == .offline)
        #expect(settings.mapRenderMode == .raster)
        #expect(settings.meshMapStyle == .osm)
        #expect(settings.lastConnectionType == .serial)
        #expect(settings.remoteAdminTimeoutSeconds == 30)
        #expect(!settings.virtualNodeEnabled)
        #expect(settings.virtualNodePort == 4404)
        #expect(!settings.fancyNodeListEnabled)
        #expect(settings.colorfulNodeListEnabled)
        #expect(!settings.kioskModeEnabled)
        #expect(settings.kioskLockedFeatures.isEmpty)
    }

    @Test("Legacy values migrate without losing user choices")
    func legacyMigration() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }
        store.defaults.set("en", forKey: "language")
        store.defaults.set(true, forKey: "darkMode")
        store.defaults.set("topography", forKey: "mapSource")
        store.defaults.set("T-Echo", forKey: "lastBtDevice")
        store.defaults.set(false, forKey: "enableMessageDb")
        store.defaults.set(365, forKey: "messageDbRetentionDays")

        let settings = SettingsService(defaults: store.defaults)

        #expect(settings.appLanguage == .english)
        #expect(settings.appearance == .dark)
        #expect(settings.meshMapStyle == .topography)
        #expect(settings.lastBluetoothDeviceName == "T-Echo")
        #expect(!settings.messageHistoryEnabled)
        #expect(settings.messageRetention == .days365)
        #expect(store.defaults.integer(forKey: "settingsSchemaVersion") == 1)
    }

    @Test("Public OpenStreetMap enforces its usage policy")
    func publicOSMPolicy() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }
        let settings = SettingsService(defaults: store.defaults)
        settings.mapRenderMode = .vector
        settings.meshMapStyle = .dark

        settings.mapMode = .publicOpenStreetMap

        #expect(settings.mapRenderMode == .raster)
        #expect(settings.meshMapStyle == .osm)

        settings.mapRenderMode = .vector
        settings.meshMapStyle = .topography
        #expect(settings.mapRenderMode == .raster)
        #expect(settings.meshMapStyle == .osm)
    }

    @Test("Numeric network settings are clamped to safe ranges")
    func numericClamping() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }
        let settings = SettingsService(defaults: store.defaults)

        settings.lastTcpPort = 100_000
        settings.virtualNodePort = 0
        settings.remoteAdminTimeoutSeconds = 2
        settings.timeSyncDriftThresholdSeconds = 1

        #expect(settings.lastTcpPort == 65_535)
        #expect(settings.virtualNodePort == 1)
        #expect(settings.remoteAdminTimeoutSeconds == 5)
        #expect(settings.timeSyncDriftThresholdSeconds == 60)

        settings.timeSyncDriftThresholdSeconds = 0
        #expect(settings.timeSyncDriftThresholdSeconds == 0)
    }

    @Test("Typed retention, overlays, kiosk mask, and connection values persist")
    func typedValuesPersist() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }
        let settings = SettingsService(defaults: store.defaults)
        settings.messageRetention = .unlimited
        settings.telemetryRetention = .unlimited
        settings.mapOverlays = [.emergency]
        settings.kioskLockedFeatures = [.nodes, .remoteAdmin, .sos]
        settings.lastConnectionType = .bluetooth
        settings.nodeKeyMismatchPolicy = .ask

        let restored = SettingsService(defaults: store.defaults)
        #expect(restored.messageRetention == .unlimited)
        #expect(restored.telemetryRetention == .unlimited)
        #expect(restored.mapOverlays == [.emergency])
        #expect(restored.kioskLockedFeatures.contains(.nodes))
        #expect(restored.kioskLockedFeatures.contains(.remoteAdmin))
        #expect(restored.kioskLockedFeatures.contains(.sos))
        #expect(restored.lastConnectionType == .bluetooth)
        #expect(restored.nodeKeyMismatchPolicy == .ask)
        #expect(restored.nodeKeyMismatchAction == .warn)
    }

    @Test("Application language changes invalidate Observation consumers")
    func languageObservation() throws {
        let store = try IsolatedDefaults()
        defer { store.cleanUp() }
        let settings = SettingsService(defaults: store.defaults)
        let didChange = LockedFlag()
        withObservationTracking {
            _ = settings.appLanguage
        } onChange: {
            didChange.set()
        }

        settings.appLanguage = .english

        #expect(didChange.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

private struct IsolatedDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "SystemSettingsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
