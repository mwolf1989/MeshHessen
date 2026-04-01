import SwiftUI
import Charts

/// Time-series chart view for node telemetry data using Swift Charts.
struct TelemetryChartView: View {
    let nodeId: UInt32
    let nodeName: String
    let days: Int

    @State private var selectedMetrics: Set<TelemetryMetric> = [.snr]
    @State private var dataPoints: [TelemetryMetric: [TimeSeriesPoint]] = [:]
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("Charts — \(nodeName)")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal)

            // Metric selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TelemetryMetric.allCases) { metric in
                        Toggle(metric.rawValue, isOn: Binding(
                            get: { selectedMetrics.contains(metric) },
                            set: { isOn in
                                if isOn { selectedMetrics.insert(metric) }
                                else { selectedMetrics.remove(metric) }
                            }
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
        .frame(minWidth: 600, minHeight: 450)
        .onAppear { loadData() }
        .onChange(of: selectedMetrics) { loadData() }
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
        let metricsToLoad = selectedMetrics
        guard !metricsToLoad.isEmpty else { return }
        isLoading = true

        Task.detached { [nodeId, days] in
            let db = TelemetryDatabaseService.shared
            let loaded: [TelemetryMetric: [TimeSeriesPoint]] = metricsToLoad.reduce(into: [:]) { dict, metric in
                dict[metric] = db.getTimeSeries(nodeId: nodeId, metric: metric, days: days)
            }
            await MainActor.run {
                dataPoints = loaded
                isLoading = false
            }
        }
    }
}
