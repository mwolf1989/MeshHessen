import Foundation
import Testing

@testable import MeshHessen

@Suite("Telemetry Settings")
struct TelemetrySettingsTests {
    private let metricsKey = "telemetryChartMetrics"

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "TelemetrySettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    @Test("Chart metrics default to SNR")
    func defaultMetrics() throws {
        let store = try makeDefaults()
        defer { store.defaults.removePersistentDomain(forName: store.suiteName) }

        let settings = SettingsService(defaults: store.defaults)

        #expect(settings.telemetryChartMetrics == [.snr])
    }

    @Test("Chart metrics persist across settings instances")
    func metricsPersist() throws {
        let store = try makeDefaults()
        defer { store.defaults.removePersistentDomain(forName: store.suiteName) }

        let settings = SettingsService(defaults: store.defaults)
        settings.telemetryChartMetrics = [.battery, .voltage]

        #expect(
            Set(store.defaults.stringArray(forKey: metricsKey) ?? [])
                == Set([TelemetryMetric.battery.rawValue, TelemetryMetric.voltage.rawValue])
        )
        #expect(SettingsService(defaults: store.defaults).telemetryChartMetrics == [.battery, .voltage])
    }

    @Test("Unknown chart metrics are ignored and invalid selections fall back to SNR")
    func invalidMetrics() throws {
        let store = try makeDefaults()
        defer { store.defaults.removePersistentDomain(forName: store.suiteName) }

        store.defaults.set(["Unknown", TelemetryMetric.rssi.rawValue], forKey: metricsKey)
        #expect(SettingsService(defaults: store.defaults).telemetryChartMetrics == [.rssi])

        store.defaults.set(["Unknown"], forKey: metricsKey)
        #expect(SettingsService(defaults: store.defaults).telemetryChartMetrics == [.snr])
    }

    @Test("An intentionally empty chart selection persists")
    func emptyMetricsPersist() throws {
        let store = try makeDefaults()
        defer { store.defaults.removePersistentDomain(forName: store.suiteName) }

        let settings = SettingsService(defaults: store.defaults)
        settings.telemetryChartMetrics = []

        #expect(SettingsService(defaults: store.defaults).telemetryChartMetrics.isEmpty)
    }
}
