import Charts
import SwiftUI

/// Value used to open or focus a telemetry chart window for a node and time range.
struct TelemetryChartWindowRequest: Codable, Hashable {
    let nodeId: UInt32
    let nodeName: String
    let days: Int
}

/// Time-series chart view for node telemetry data using Swift Charts.
struct TelemetryChartView: View {
    let nodeId: UInt32
    let nodeName: String
    let days: Int

    @State private var settings = SettingsService.shared
    @State private var dataPoints: [TelemetryMetric: [TimeSeriesPoint]] = [:]
    @State private var isLoading = false
    @State private var loadGeneration = 0
    @Environment(\.dismissWindow) private var dismissWindow

    private var selectedMetrics: Set<TelemetryMetric> {
        settings.telemetryChartMetrics
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("Charts — \(nodeName)")
                    .font(.headline)
                Spacer()
                Button("Close") { dismissWindow() }
            }
            .padding(.horizontal)

            // Metric selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TelemetryMetric.allCases) { metric in
                        Toggle(metric.rawValue, isOn: Binding(
                            get: { selectedMetrics.contains(metric) },
                            set: { setMetric(metric, isSelected: $0) }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }

            if isLoading {
                ProgressView("Loading data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedMetrics.isEmpty {
                ContentUnavailableView("Select Metrics", systemImage: "chart.xyaxis.line", description: Text("Choose one or more metrics above to display charts."))
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(Array(selectedMetrics).sorted(by: { $0.rawValue < $1.rawValue })) { metric in
                            chartSection(for: metric)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.vertical)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { loadData() }
        .onChange(of: selectedMetrics) { loadData() }
        .onReceive(NotificationCenter.default.publisher(
            for: .telemetryDatabaseDidClear,
            object: TelemetryDatabaseService.shared
        )) { _ in
            loadData()
        }
    }

    private func setMetric(_ metric: TelemetryMetric, isSelected: Bool) {
        var metrics = selectedMetrics
        if isSelected {
            metrics.insert(metric)
        } else {
            metrics.remove(metric)
        }
        settings.telemetryChartMetrics = metrics
    }

    @ViewBuilder
    private func chartSection(for metric: TelemetryMetric) -> some View {
        let points = dataPoints[metric] ?? []

        GroupBox {
            if points.isEmpty {
                Text("No data available")
                    .foregroundStyle(.secondary)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value(metric.rawValue, point.value)
                        )
                        .foregroundStyle(point.isDay ? Color.accentColor : Color.indigo)
                        .interpolationMethod(.catmullRom)
                    }

                    // Add point markers if data is sparse
                    if points.count < 100 {
                        ForEach(points) { point in
                            PointMark(
                                x: .value("Time", point.timestamp),
                                y: .value(metric.rawValue, point.value)
                            )
                            .foregroundStyle(point.isDay ? Color.accentColor : Color.indigo)
                            .symbolSize(20)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .modifier(MetricYScaleModifier(metric: metric))
                .frame(height: 200)
            }
        } label: {
            HStack {
                Text(metric.rawValue)
                    .font(.subheadline).bold()
                Spacer()
                Text("\(points.count) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadData() {
        loadGeneration &+= 1
        let generation = loadGeneration
        let metricsToLoad = selectedMetrics
        guard !metricsToLoad.isEmpty else {
            dataPoints = [:]
            isLoading = false
            return
        }
        isLoading = true

        Task.detached { [nodeId, days] in
            let db = TelemetryDatabaseService.shared
            let loaded: [TelemetryMetric: [TimeSeriesPoint]] = metricsToLoad.reduce(into: [:]) { dict, metric in
                dict[metric] = db.getTimeSeries(nodeId: nodeId, metric: metric, days: days)
            }
            await MainActor.run {
                guard loadGeneration == generation, selectedMetrics == metricsToLoad else {
                    return
                }
                dataPoints = loaded
                isLoading = false
            }
        }
    }
}

private struct MetricYScaleModifier: ViewModifier {
    let metric: TelemetryMetric

    @ViewBuilder
    func body(content: Content) -> some View {
        if metric == .voltage {
            content.chartYScale(domain: 0.0...5.0)
        } else {
            content
        }
    }
}
