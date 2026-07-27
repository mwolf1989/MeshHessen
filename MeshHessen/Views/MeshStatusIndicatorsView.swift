import SwiftUI

/// Compact live health indicators equivalent to the Windows status LEDs.
struct MeshStatusIndicatorsView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var meshHealth: TelemetryMeshHealthSummary?
    @State private var refreshGeneration = 0

    var body: some View {
        HStack(spacing: 5) {
            statusIndicator(
                symbol: "waveform.path.ecg",
                color: signalColor,
                title: String(localized: "Signal"),
                detail: signalDetail
            )
            statusIndicator(
                symbol: "person.2.fill",
                color: neighborColor,
                title: String(localized: "Direct Neighbors"),
                detail: neighborDetail
            )
            statusIndicator(
                symbol: "point.topleft.down.to.point.bottomright.curvepath",
                color: pathColor,
                title: String(localized: "Path Stability"),
                detail: pathDetail
            )
            statusIndicator(
                symbol: "network",
                color: meshColor,
                title: String(localized: "Mesh Health"),
                detail: meshDetail
            )
            statusIndicator(
                symbol: "cloud.sun.fill",
                color: weatherColor,
                title: String(localized: "Weather Sensors"),
                detail: weatherDetail
            )
        }
        .task {
            while !Task.isCancelled {
                await refreshMeshHealth()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .telemetryDatabaseDidClear,
            object: TelemetryDatabaseService.shared
        )) { _ in
            refreshGeneration &+= 1
            let generation = refreshGeneration
            meshHealth = nil
            Task { await refreshMeshHealth(generation: generation) }
        }
    }

    private func statusIndicator(
        symbol: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 19, height: 19)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
            .help("\(title): \(detail)")
            .accessibilityLabel(Text(title))
            .accessibilityValue(detail)
    }

    private var recentDirectNodes: [NodeInfo] {
        let cutoff = Int32(Date().addingTimeInterval(-86_400).timeIntervalSince1970)
        return appState.nodes.values.filter {
            $0.isDirectRF && $0.lastDirectHeard >= cutoff
        }
    }

    private var averageDirectSnr: Double? {
        let values = recentDirectNodes.compactMap(\.directSnr).map(Double.init)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var signalColor: Color {
        guard let averageDirectSnr else { return .gray }
        if averageDirectSnr >= 0 { return .green }
        if averageDirectSnr >= -10 { return .yellow }
        return .red
    }

    private var signalDetail: String {
        guard let averageDirectSnr else { return String(localized: "No direct RF data") }
        return String(format: String(localized: "Average %.1f dB"), averageDirectSnr)
    }

    private var neighborColor: Color {
        switch recentDirectNodes.count {
        case 3...: return .green
        case 1...2: return .yellow
        default: return .gray
        }
    }

    private var neighborDetail: String {
        String(localized: "\(recentDirectNodes.count) direct RF node(s) in 24 hours")
    }

    private var recentTraceroutes: [TracerouteResult] {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return coordinator.tracerouteResults.filter { ($0.responseTime ?? .distantPast) >= cutoff }
    }

    private var pathColor: Color {
        guard !recentTraceroutes.isEmpty else { return .gray }
        let grouped = Dictionary(grouping: recentTraceroutes, by: \.targetNodeId)
        let stableTargets = grouped.values.filter { results in
            Set(results.map { $0.hops.count }).count <= 1
        }.count
        let ratio = Double(stableTargets) / Double(max(1, grouped.count))
        if ratio >= 0.75 { return .green }
        if ratio >= 0.4 { return .yellow }
        return .red
    }

    private var pathDetail: String {
        guard !recentTraceroutes.isEmpty else { return String(localized: "No recent traceroutes") }
        return String(localized: "\(recentTraceroutes.count) route(s) in 7 days")
    }

    private var meshColor: Color {
        switch meshHealth?.state ?? .noData {
        case .good: return .green
        case .warning: return .yellow
        case .alert: return .red
        case .noData: return .gray
        }
    }

    private var meshDetail: String {
        guard let meshHealth else { return String(localized: "No telemetry data") }
        return String(format: String(localized: "Health score %.0f of 100"), meshHealth.score)
    }

    private var weatherNodes: [NodeInfo] {
        appState.nodes.values.filter {
            $0.temperature != nil || $0.relativeHumidity != nil || $0.barometricPressure != nil
        }
    }

    private var weatherColor: Color {
        weatherNodes.isEmpty ? .gray : .green
    }

    private var weatherDetail: String {
        String(localized: "\(weatherNodes.count) node(s) with environmental telemetry")
    }

    private func refreshMeshHealth() async {
        refreshGeneration &+= 1
        await refreshMeshHealth(generation: refreshGeneration)
    }

    private func refreshMeshHealth(generation: Int) async {
        let nodeIDs = Array(appState.nodes.keys)
        let summary = await Task.detached {
            TelemetryDatabaseService.shared.getMeshHealthSummary(nodeIds: nodeIDs, days: 1)
        }.value
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        meshHealth = summary
    }
}
