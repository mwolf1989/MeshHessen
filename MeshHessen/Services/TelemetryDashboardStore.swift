import Foundation
import Observation

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

    private static let currentSchemaVersion = 1
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
