import Foundation
import Observation
import UserNotifications

/// UserDefaults-backed dashboard layout store.
///
/// The store owns dashboard mutations so every change is normalized and persisted
/// atomically as a single Codable document.
@MainActor
@Observable
final class TelemetryDashboardStore {
    static let shared = TelemetryDashboardStore()

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var selectedDashboardID: UUID?
        var dashboards: [TelemetryDashboard]
    }

    private static let currentSchemaVersion = 2
    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var dashboards: [TelemetryDashboard]
    private(set) var selectedDashboardID: UUID?
    private(set) var lastPersistenceError: String?

    convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults, storageKey: String = "telemetryDashboardStore.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        if let data = defaults.data(forKey: storageKey),
           let state = try? decoder.decode(PersistedState.self, from: data),
           !state.dashboards.isEmpty {
            var normalized = state.dashboards
            for index in normalized.indices { normalized[index].normalize() }
            self.dashboards = normalized
            if let selected = state.selectedDashboardID,
               normalized.contains(where: { $0.id == selected }) {
                self.selectedDashboardID = selected
            } else {
                self.selectedDashboardID = normalized.first?.id
            }
        } else {
            let dashboard = TelemetryDashboard(name: String(localized: "Overview"))
            self.dashboards = [dashboard]
            self.selectedDashboardID = dashboard.id
        }
    }

    var currentDashboard: TelemetryDashboard? {
        if let selectedDashboardID,
           let selected = dashboards.first(where: { $0.id == selectedDashboardID }) {
            return selected
        }
        return dashboards.first
    }

    @discardableResult
    func addDashboard(named name: String) -> UUID {
        var dashboard = TelemetryDashboard(name: name)
        dashboard.normalize()
        dashboards.append(dashboard)
        selectedDashboardID = dashboard.id
        persist()
        return dashboard.id
    }

    func selectDashboard(id: UUID) {
        guard dashboards.contains(where: { $0.id == id }), selectedDashboardID != id else { return }
        selectedDashboardID = id
        persist()
    }

    func renameDashboard(id: UUID, to name: String) {
        guard let index = dashboards.firstIndex(where: { $0.id == id }) else { return }
        dashboards[index].name = name
        dashboards[index].normalize()
        persist()
    }

    func deleteDashboard(id: UUID) {
        guard dashboards.count > 1,
              let index = dashboards.firstIndex(where: { $0.id == id }) else { return }
        dashboards.remove(at: index)
        if selectedDashboardID == id {
            selectedDashboardID = dashboards[min(index, dashboards.count - 1)].id
        }
        persist()
    }

    func addWidget(_ widget: TelemetryDashboardWidget, to dashboardID: UUID? = nil) {
        guard let index = dashboardIndex(id: dashboardID) else { return }
        var normalized = widget
        normalized.normalize()
        if dashboards[index].widgets.contains(where: { $0.id == normalized.id }) {
            normalized.id = UUID()
        }
        dashboards[index].widgets.append(normalized)
        persist()
    }

    func updateWidget(_ widget: TelemetryDashboardWidget, in dashboardID: UUID? = nil) {
        guard let dashboardIndex = dashboardIndex(id: dashboardID),
              let widgetIndex = dashboards[dashboardIndex].widgets.firstIndex(where: { $0.id == widget.id }) else {
            return
        }
        var normalized = widget
        normalized.normalize()
        dashboards[dashboardIndex].widgets[widgetIndex] = normalized
        persist()
    }

    func removeWidget(id: UUID, from dashboardID: UUID? = nil) {
        guard let index = dashboardIndex(id: dashboardID) else { return }
        let oldCount = dashboards[index].widgets.count
        dashboards[index].widgets.removeAll { $0.id == id }
        if dashboards[index].widgets.count != oldCount { persist() }
    }

    func resizeWidget(
        id: UUID,
        width: Double,
        height: Double,
        in dashboardID: UUID? = nil
    ) {
        guard let dashboardIndex = dashboardIndex(id: dashboardID),
              let widgetIndex = dashboards[dashboardIndex].widgets.firstIndex(where: { $0.id == id }) else {
            return
        }
        dashboards[dashboardIndex].widgets[widgetIndex].width = max(
            TelemetryDashboardWidget.minimumWidth,
            width
        )
        dashboards[dashboardIndex].widgets[widgetIndex].height = max(
            TelemetryDashboardWidget.minimumHeight,
            height
        )
        persist()
    }

    func reorderWidget(sourceID: UUID, before targetID: UUID, in dashboardID: UUID? = nil) {
        guard sourceID != targetID,
              let dashboardIndex = dashboardIndex(id: dashboardID) else { return }
        var widgets = dashboards[dashboardIndex].widgets
        guard let sourceIndex = widgets.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = widgets.firstIndex(where: { $0.id == targetID }) else { return }

        let widget = widgets.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        widgets.insert(widget, at: adjustedTarget)
        dashboards[dashboardIndex].widgets = widgets
        persist()
    }

    func updateDays(_ days: Int, widgetID: UUID, in dashboardID: UUID? = nil) {
        guard let dashboardIndex = dashboardIndex(id: dashboardID),
              let widgetIndex = dashboards[dashboardIndex].widgets.firstIndex(where: { $0.id == widgetID }) else {
            return
        }
        dashboards[dashboardIndex].widgets[widgetIndex].days = days
        dashboards[dashboardIndex].widgets[widgetIndex].normalize()
        persist()
    }

    func encodedState() throws -> Data {
        try encoder.encode(PersistedState(
            schemaVersion: Self.currentSchemaVersion,
            selectedDashboardID: selectedDashboardID,
            dashboards: dashboards
        ))
    }

    @discardableResult
    func importState(_ data: Data) -> Bool {
        do {
            let decoded = try decoder.decode(PersistedState.self, from: data)
            guard !decoded.dashboards.isEmpty else { return false }
            var normalized = decoded.dashboards
            for index in normalized.indices { normalized[index].normalize() }
            dashboards = normalized
            selectedDashboardID = decoded.selectedDashboardID.flatMap { selected in
                normalized.contains(where: { $0.id == selected }) ? selected : nil
            } ?? normalized.first?.id
            persist()
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            return false
        }
    }

    func reset() {
        let dashboard = TelemetryDashboard(name: String(localized: "Overview"))
        dashboards = [dashboard]
        selectedDashboardID = dashboard.id
        persist()
    }

    // MARK: - Private

    private func dashboardIndex(id: UUID?) -> Int? {
        let targetID = id ?? selectedDashboardID ?? dashboards.first?.id
        guard let targetID else { return nil }
        return dashboards.firstIndex(where: { $0.id == targetID })
    }

    private func persist() {
        do {
            let data = try encodedState()
            defaults.set(data, forKey: storageKey)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            AppLogger.shared.log("[TelemetryDashboard] Persist failed: \(error)")
        }
    }
}

struct AppNotification: Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String
}

protocol SystemNotificationDelivering: Sendable {
    func deliver(_ notification: AppNotification) async
}

actor SystemNotificationService: SystemNotificationDelivering {
    static let shared = SystemNotificationService()

    func deliver(_ notification: AppNotification) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let isAuthorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            isAuthorized = true
        case .notDetermined:
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLogger.shared.log(
                    "[Notifications] Authorization failed: \(error.localizedDescription)",
                    debug: true
                )
                return
            }
        case .denied:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard isAuthorized else {
            AppLogger.shared.log("[Notifications] Authorization denied", debug: true)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.categoryIdentifier

        do {
            try await center.add(UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: nil
            ))
        } catch {
            AppLogger.shared.log(
                "[Notifications] Delivery failed: \(error.localizedDescription)",
                debug: true
            )
        }
    }
}

struct TelemetrySampleBatch: Sendable {
    let nodeID: UInt32
    let timestamp: Date
    let values: [TelemetrySeriesMetric: Double]
}

@MainActor
final class TelemetryAlarmService {
    static let shared = TelemetryAlarmService(dashboardStore: .shared)

    /// Widgets with identical node, metric and bounds share one rule, so the same
    /// zone change on several dashboards notifies once.
    private struct Rule: Hashable {
        let nodeID: UInt32
        let metric: TelemetrySeriesMetric
        let warnMinimum: Double?
        let warnMaximum: Double?
        let alarmMinimum: Double?
        let alarmMaximum: Double?

        var persistenceKey: String {
            let bounds = [warnMinimum, warnMaximum, alarmMinimum, alarmMaximum].map { bound in
                bound.map { String($0.bitPattern, radix: 16) } ?? "none"
            }
            return "\(nodeID):\(metric.rawValue):\(bounds.joined(separator: ":"))"
        }

        func zone(for value: Double) -> TelemetryZone {
            TelemetryAlarmEvaluator.zone(
                value: value,
                warnMinimum: warnMinimum,
                warnMaximum: warnMaximum,
                alarmMinimum: alarmMinimum,
                alarmMaximum: alarmMaximum
            )
        }

        func bound(for zone: TelemetryZone) -> Double? {
            switch zone {
            case .ok: return nil
            case .warnLow: return warnMinimum
            case .warnHigh: return warnMaximum
            case .alarmLow: return alarmMinimum
            case .alarmHigh: return alarmMaximum
            }
        }
    }

    private let dashboardStore: TelemetryDashboardStore
    private let defaults: UserDefaults
    private let stateStorageKey: String
    private let notifications: any SystemNotificationDelivering
    private let radiationInSievert: () -> Bool
    private var states: [String: TelemetryZone]

    init(
        dashboardStore: TelemetryDashboardStore,
        defaults: UserDefaults = .standard,
        stateStorageKey: String = "telemetryAlarmZones.v2",
        notifications: any SystemNotificationDelivering = SystemNotificationService.shared,
        radiationInSievert: @escaping () -> Bool = { SettingsService.shared.radiationInSievert }
    ) {
        self.dashboardStore = dashboardStore
        self.radiationInSievert = radiationInSievert
        self.defaults = defaults
        self.stateStorageKey = stateStorageKey
        self.notifications = notifications
        if let data = defaults.data(forKey: stateStorageKey),
           let decoded = try? JSONDecoder().decode(
               [String: TelemetryZone].self,
               from: data
           ) {
            self.states = decoded
        } else {
            self.states = [:]
        }
    }

    func process(_ batch: TelemetrySampleBatch) async {
        var didChange = false
        let inSievert = radiationInSievert()
        for (metric, storedValue) in batch.values where storedValue.isFinite {
            // Alarm bounds are entered in the displayed unit.
            let value = metric.displayValue(storedValue, radiationInSievert: inSievert)
            let rules = rules(nodeID: batch.nodeID, metric: metric)
            for (rule, title) in rules.sorted(by: { $0.key.persistenceKey < $1.key.persistenceKey }) {
                let key = rule.persistenceKey
                // Unknown rules start as ok, so a first ok reading after launch is silent.
                let previous = states[key] ?? .ok
                let current = rule.zone(for: value)
                guard previous != current else { continue }
                states[key] = current
                didChange = true

                if TelemetryAlarmEvaluator.shouldNotify(previous: previous, current: current) {
                    await notifications.deliver(notification(
                        for: rule,
                        widgetTitle: title,
                        zone: current,
                        value: value,
                        unit: metric.displayUnit(radiationInSievert: inSievert),
                        timestamp: batch.timestamp
                    ))
                }
            }
        }

        if didChange {
            persistStates()
            NotificationCenter.default.post(name: .telemetryAlarmStateDidChange, object: self)
        }
    }

    /// Active rules for a sample, each with the title of the first widget that defines it.
    private func rules(nodeID: UInt32, metric: TelemetrySeriesMetric) -> [Rule: String] {
        var result: [Rule: String] = [:]
        for widget in dashboardStore.dashboards.flatMap(\.widgets) {
            guard widget.type.usesMetric,
                  widget.metric == metric,
                  widget.hasZones,
                  matches(widget: widget, nodeID: nodeID) else {
                continue
            }
            let rule = Rule(
                nodeID: nodeID,
                metric: metric,
                warnMinimum: widget.warnMinimum,
                warnMaximum: widget.warnMaximum,
                alarmMinimum: widget.alarmMinimum,
                alarmMaximum: widget.alarmMaximum
            )
            if result[rule] == nil { result[rule] = widget.effectiveTitle }
        }
        return result
    }

    private func matches(widget: TelemetryDashboardWidget, nodeID: UInt32) -> Bool {
        if widget.nodeIds.isEmpty { return widget.type.allowsMultipleNodes }
        return widget.nodeIds.contains(nodeID)
    }

    private func notification(
        for rule: Rule,
        widgetTitle: String,
        zone: TelemetryZone,
        value: Double,
        unit: String,
        timestamp: Date
    ) -> AppNotification {
        let nodeName = TelemetryDashboardNode.fallbackName(for: rule.nodeID)
        let valueText = Self.formatted(value)
        let boundText = rule.bound(for: zone).map(Self.formatted) ?? valueText
        let title: String
        let condition: String
        switch zone {
        case .ok:
            title = String(localized: "✅ \(widgetTitle): back to normal")
            condition = String(localized: "within the normal range")
        case .warnLow:
            title = String(localized: "⚠ \(widgetTitle): \(valueText) \(unit)")
            condition = String(localized: "at or below the warning limit of \(boundText)")
        case .warnHigh:
            title = String(localized: "⚠ \(widgetTitle): \(valueText) \(unit)")
            condition = String(localized: "at or above the warning limit of \(boundText)")
        case .alarmLow:
            title = String(localized: "🚨 \(widgetTitle): \(valueText) \(unit)")
            condition = String(localized: "at or below the alarm limit of \(boundText)")
        case .alarmHigh:
            title = String(localized: "🚨 \(widgetTitle): \(valueText) \(unit)")
            condition = String(localized: "at or above the alarm limit of \(boundText)")
        }
        return AppNotification(
            identifier: "telemetry-\(rule.persistenceKey)-\(timestamp.timeIntervalSince1970)",
            title: title,
            body: String(localized: "\(nodeName): \(valueText) \(unit), \(condition)"),
            categoryIdentifier: "TELEMETRY_ALARM"
        )
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func persistStates() {
        do {
            defaults.set(try JSONEncoder().encode(states), forKey: stateStorageKey)
        } catch {
            AppLogger.shared.log("[TelemetryAlarm] State persistence failed: \(error)")
        }
    }
}
