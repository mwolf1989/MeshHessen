import Charts
import SwiftUI

struct TelemetryDashboardWidgetCard: View {
    let widget: TelemetryDashboardWidget
    let nodeNames: [UInt32: String]
    let loader: TelemetryDashboardDataLoader
    let refreshToken: Int
    let onEdit: (TelemetryDashboardWidget) -> Void
    let onRemove: (TelemetryDashboardWidget) -> Void
    let onDaysChanged: (Int, TelemetryDashboardWidget) -> Void
    let onExport: (TelemetryDashboardWidget, TelemetryDashboardSnapshot) -> Void

    @State private var snapshot = TelemetryDashboardSnapshot()
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            ZStack {
                TelemetryWidgetContent(
                    widget: widget,
                    snapshot: snapshot,
                    nodeNames: nodeNames
                )
                .padding(10)

                if isLoading, widget.type != .clock {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(hasActiveAlarm ? Color.red.opacity(0.08) : Color.clear)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hasActiveAlarm ? Color.red : Color.secondary.opacity(0.2),
                    lineWidth: hasActiveAlarm ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.07), radius: 4, y: 2)
        .contextMenu {
            Button("Bearbeiten", systemImage: "pencil") { onEdit(widget) }
            Menu("Zeitraum") { timeRangeButtons }
                .disabled(widget.type == .clock)
            Button("CSV exportieren", systemImage: "square.and.arrow.up") {
                onExport(widget, snapshot)
            }
            .disabled(snapshot.series.isEmpty)
            Divider()
            Button("Entfernen", systemImage: "trash", role: .destructive) { onRemove(widget) }
        }
        .task(id: LoadKey(
            widget: widget,
            refreshToken: refreshToken,
            knownNodeIDs: nodeNames.keys.sorted()
        )) {
            await load()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(widget.effectiveTitle)
    }

    private var cardHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: widget.type.systemImage)
                .foregroundStyle(typeColor)
            Text(widget.effectiveTitle)
                .font(.headline)
                .lineLimit(1)
            if let alarmReading {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(alarmDescription(for: alarmReading))
                    .accessibilityLabel(alarmDescription(for: alarmReading))
            }
            Spacer(minLength: 6)
            if widget.type != .clock {
                Menu {
                    timeRangeButtons
                } label: {
                    Text(
                        widget.days == 0
                            ? String(localized: "All")
                            : String(localized: "\(widget.days) d")
                    )
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .help("Zeitraum ändern")
            }
            Menu {
                Button("Bearbeiten", systemImage: "pencil") { onEdit(widget) }
                Button("CSV exportieren", systemImage: "square.and.arrow.up") {
                    onExport(widget, snapshot)
                }
                .disabled(snapshot.series.isEmpty)
                Divider()
                Button("Entfernen", systemImage: "trash", role: .destructive) { onRemove(widget) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("Widget-Aktionen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(typeColor.opacity(0.06))
    }

    @ViewBuilder
    private var timeRangeButtons: some View {
        ForEach([1, 7, 14, 30, 0], id: \.self) { days in
            Button(
                days == 0
                    ? String(localized: "All Data")
                    : String(localized: "\(days) Days")
            ) {
                onDaysChanged(days, widget)
            }
        }
    }

    private var typeColor: Color {
        switch widget.type {
        case .line: return .blue
        case .area, .histogram, .ranking: return .green
        case .bar, .clock, .meshhealth: return .orange
        case .gauge: return .purple
        case .stat, .stateline, .multistat: return .cyan
        case .heatmap, .candlestick: return .red
        case .scatter: return .indigo
        }
    }

    private var alarmReading: (state: TelemetryAlarmState, point: TelemetrySeriesPoint)? {
        guard widget.hasAlarm else { return nil }
        for point in snapshot.latestByNode.values.sorted(by: { $0.nodeId < $1.nodeId }) {
            let state = TelemetryAlarmEvaluator.state(
                value: point.value,
                minimum: widget.alarmMinimum,
                maximum: widget.alarmMaximum
            )
            if state != .normal { return (state, point) }
        }
        return nil
    }

    private var hasActiveAlarm: Bool { alarmReading != nil }

    private func alarmDescription(
        for reading: (state: TelemetryAlarmState, point: TelemetrySeriesPoint)
    ) -> String {
        let node = nodeNames[reading.point.nodeId]
            ?? TelemetryDashboardNode.fallbackName(for: reading.point.nodeId)
        switch reading.state {
        case .belowMinimum:
            return String(localized: "\(node) is below the alarm minimum")
        case .aboveMaximum:
            return String(localized: "\(node) is above the alarm maximum")
        case .normal:
            return String(localized: "\(node) is within the normal range")
        }
    }

    private func load() async {
        guard widget.type != .clock else { return }
        isLoading = true
        let loaded = await loader.load(
            widget: widget,
            fallbackNodeIds: nodeNames.keys.sorted()
        )
        guard !Task.isCancelled else { return }
        snapshot = loaded
        isLoading = false
    }

    private struct LoadKey: Hashable {
        let widget: TelemetryDashboardWidget
        let refreshToken: Int
        let knownNodeIDs: [UInt32]
    }
}

private struct TelemetryWidgetContent: View {
    let widget: TelemetryDashboardWidget
    let snapshot: TelemetryDashboardSnapshot
    let nodeNames: [UInt32: String]

    var body: some View {
        switch widget.type {
        case .line:
            DashboardLineChart(
                widget: widget,
                points: snapshot.series,
                nodeNames: nodeNames,
                area: false
            )
        case .area:
            DashboardLineChart(
                widget: widget,
                points: snapshot.series,
                nodeNames: nodeNames,
                area: true
            )
        case .bar:
            DashboardBarChart(widget: widget, points: snapshot.series, nodeNames: nodeNames)
        case .scatter:
            DashboardScatterChart(widget: widget, points: snapshot.series, nodeNames: nodeNames)
        case .gauge:
            DashboardGauge(widget: widget, points: snapshot.series, nodeNames: nodeNames)
        case .stat:
            DashboardStat(widget: widget, points: snapshot.series, nodeNames: nodeNames)
        case .heatmap:
            DashboardHeatmap(widget: widget, cells: snapshot.heatmap)
        case .histogram:
            DashboardHistogram(widget: widget, bins: snapshot.histogram)
        case .candlestick:
            DashboardCandlestick(widget: widget, candles: snapshot.candles)
        case .stateline:
            DashboardStateTimeline(cells: snapshot.heatmap)
        case .ranking:
            DashboardRanking(widget: widget, snapshot: snapshot, nodeNames: nodeNames)
        case .multistat:
            DashboardMultiStat(widget: widget, snapshot: snapshot, nodeNames: nodeNames)
        case .meshhealth:
            DashboardMeshHealth(snapshot: snapshot, nodeNames: nodeNames)
        case .clock:
            DashboardClock()
        }
    }
}

private struct DashboardLineChart: View {
    let widget: TelemetryDashboardWidget
    let points: [TelemetrySeriesPoint]
    let nodeNames: [UInt32: String]
    let area: Bool

    private var movingAverage: [TelemetrySeriesPoint] {
        guard widget.showMovingAverage else { return [] }
        let window: TimeInterval = widget.days <= 1 ? 3_600 : 21_600
        return TelemetryDatabaseService.rollingAverage(points, window: window)
    }

    var body: some View {
        if points.isEmpty {
            DashboardNoData()
        } else {
            Chart {
                ForEach(points) { point in
                    if area {
                        AreaMark(
                            x: .value(String(localized: "Time"), point.timestamp),
                            y: .value(widget.metric.displayName, point.value)
                        )
                        .foregroundStyle(by: .value("Node", nodeLabel(point.nodeId)))
                        .opacity(0.22)
                    }
                    LineMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(widget.metric.displayName, point.value)
                    )
                    .foregroundStyle(by: .value("Node", nodeLabel(point.nodeId)))
                    .interpolationMethod(.catmullRom)
                }
                ForEach(movingAverage) { point in
                    LineMark(
                        x: .value(String(localized: "Time"), point.timestamp),
                        y: .value(String(localized: "Average"), point.value),
                        series: .value(String(localized: "Series"), "\(nodeLabel(point.nodeId)) Ø")
                    )
                    .foregroundStyle(by: .value("Node", "\(nodeLabel(point.nodeId)) Ø"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                if let threshold = widget.threshold {
                    RuleMark(y: .value(String(localized: "Threshold"), threshold))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(threshold, format: .number.precision(.fractionLength(1)))")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .modifier(DashboardMetricScale(widget: widget))
        }
    }

    private func nodeLabel(_ nodeId: UInt32) -> String {
        nodeNames[nodeId] ?? TelemetryDashboardNode.fallbackName(for: nodeId)
    }
}

private struct DashboardBarChart: View {
    let widget: TelemetryDashboardWidget
    let points: [TelemetrySeriesPoint]
    let nodeNames: [UInt32: String]

    private var aggregates: [DashboardAggregatePoint] {
        let calendar = Calendar(identifier: .gregorian)
        let grouped = Dictionary(grouping: points) { point in
            DashboardAggregateKey(nodeId: point.nodeId, date: calendar.startOfDay(for: point.timestamp))
        }
        return grouped.map { key, values in
            DashboardAggregatePoint(
                nodeId: key.nodeId,
                date: key.date,
                value: values.map(\.value).reduce(0, +) / Double(values.count)
            )
        }.sorted { $0.date < $1.date }
    }

    var body: some View {
        if aggregates.isEmpty {
            DashboardNoData()
        } else {
            Chart(aggregates) { point in
                BarMark(
                    x: .value(String(localized: "Day"), point.date, unit: .day),
                    y: .value(widget.metric.displayName, point.value)
                )
                .foregroundStyle(by: .value(
                    "Node",
                    nodeNames[point.nodeId]
                        ?? TelemetryDashboardNode.fallbackName(for: point.nodeId)
                ))
                .position(by: .value("Node-ID", point.nodeId))
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .modifier(DashboardMetricScale(widget: widget))
        }
    }
}

private struct DashboardScatterChart: View {
    let widget: TelemetryDashboardWidget
    let points: [TelemetrySeriesPoint]
    let nodeNames: [UInt32: String]

    var body: some View {
        if points.isEmpty {
            DashboardNoData()
        } else {
            Chart(points) { point in
                PointMark(
                    x: .value(String(localized: "Time"), point.timestamp),
                    y: .value(widget.metric.displayName, point.value)
                )
                .foregroundStyle(by: .value(
                    "Node",
                    nodeNames[point.nodeId]
                        ?? TelemetryDashboardNode.fallbackName(for: point.nodeId)
                ))
                .symbolSize(28)
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .modifier(DashboardMetricScale(widget: widget))
        }
    }
}

private struct DashboardGauge: View {
    let widget: TelemetryDashboardWidget
    let points: [TelemetrySeriesPoint]
    let nodeNames: [UInt32: String]

    private var latest: TelemetrySeriesPoint? {
        points.max { $0.timestamp < $1.timestamp }
    }

    private var range: ClosedRange<Double> {
        if let configured = widget.effectiveDisplayRange { return configured }
        let values = points.map(\.value)
        let minimum = min(0, values.min() ?? 0)
        let maximum = values.max() ?? 1
        return minimum...(maximum > minimum ? maximum : minimum + 1)
    }

    var body: some View {
        if let latest {
            VStack(spacing: 8) {
                Gauge(value: min(max(latest.value, range.lowerBound), range.upperBound), in: range) {
                    Text(widget.metric.displayName)
                } currentValueLabel: {
                    Text(latest.value, format: .number.precision(.fractionLength(1)))
                        .font(.title2.monospacedDigit())
                } minimumValueLabel: {
                    Text(range.lowerBound, format: .number.precision(.fractionLength(0)))
                } maximumValueLabel: {
                    Text(range.upperBound, format: .number.precision(.fractionLength(0)))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(Gradient(colors: [.red, .orange, .green]))
                .scaleEffect(1.35)
                .padding(18)

                Text(widget.metric.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    nodeNames[latest.nodeId]
                        ?? TelemetryDashboardNode.fallbackName(for: latest.nodeId)
                )
                    .font(.caption)
                    .lineLimit(1)
                Text(latest.timestamp, format: .dateTime.day().month().hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        } else {
            DashboardNoData()
        }
    }
}

private struct DashboardStat: View {
    let widget: TelemetryDashboardWidget
    let points: [TelemetrySeriesPoint]
    let nodeNames: [UInt32: String]

    var body: some View {
        if let latest = points.max(by: { $0.timestamp < $1.timestamp }) {
            let values = points.map(\.value)
            VStack(spacing: 10) {
                Text(latest.value, format: .number.precision(.fractionLength(1)))
                    .font(.system(.largeTitle, design: .rounded).weight(.light))
                    .monospacedDigit()
                Text(widget.metric.unit)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(
                    nodeNames[latest.nodeId]
                        ?? TelemetryDashboardNode.fallbackName(for: latest.nodeId)
                )
                    .lineLimit(1)
                Divider()
                HStack(spacing: 16) {
                    MiniValue(label: "Min", value: values.min() ?? 0)
                    MiniValue(label: "Ø", value: values.reduce(0, +) / Double(values.count))
                    MiniValue(label: "Max", value: values.max() ?? 0)
                }
                Text(latest.timestamp, format: .dateTime.day().month().hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        } else {
            DashboardNoData()
        }
    }
}

private struct DashboardHeatmap: View {
    let widget: TelemetryDashboardWidget
    let cells: [TelemetryHeatmapCell]

    private var bounds: (minimum: Double, maximum: Double) {
        if let range = widget.effectiveDisplayRange {
            return (range.lowerBound, range.upperBound)
        }
        let values = cells.map(\.value)
        return (values.min() ?? 0, values.max() ?? 1)
    }

    var body: some View {
        if cells.isEmpty {
            DashboardNoData()
        } else {
            Chart(cells) { cell in
                RectangleMark(
                    x: .value(String(localized: "Day"), cell.dayIndex),
                    y: .value(String(localized: "Hour"), cell.hour)
                )
                .foregroundStyle(Color.accentColor.opacity(opacity(for: cell.value)))
            }
            .chartXAxisLabel("Tag im Zeitraum")
            .chartYAxisLabel("Stunde")
            .chartYScale(domain: 0...23)
        }
    }

    private func opacity(for value: Double) -> Double {
        let span = bounds.maximum - bounds.minimum
        guard span > 0 else { return 0.85 }
        let normalized = min(1, max(0, (value - bounds.minimum) / span))
        return 0.12 + 0.88 * normalized
    }
}

private struct DashboardHistogram: View {
    let widget: TelemetryDashboardWidget
    let bins: [TelemetryHistogramBin]

    var body: some View {
        if bins.isEmpty {
            DashboardNoData()
        } else {
            Chart(bins) { bin in
                BarMark(
                    xStart: .value(String(localized: "From"), bin.lowerBound),
                    xEnd: .value(String(localized: "To"), bin.upperBound),
                    y: .value(String(localized: "Count"), bin.count)
                )
                .foregroundStyle(.green.gradient)
            }
            .chartXAxisLabel(widget.metric.unit)
            .chartYAxisLabel("Messungen")
            .modifier(DashboardHistogramScale(widget: widget))
        }
    }
}

private struct DashboardCandlestick: View {
    let widget: TelemetryDashboardWidget
    let candles: [TelemetryCandlePoint]

    var body: some View {
        if candles.isEmpty {
            DashboardNoData()
        } else {
            Chart(candles) { candle in
                RuleMark(
                    x: .value(String(localized: "Day"), candle.date, unit: .day),
                    yStart: .value(String(localized: "Low"), candle.low),
                    yEnd: .value(String(localized: "High"), candle.high)
                )
                .foregroundStyle(candle.close >= candle.open ? .green : .red)
                RectangleMark(
                    x: .value(String(localized: "Day"), candle.date, unit: .day),
                    yStart: .value(String(localized: "dashboard.candlestick.open", defaultValue: "Open"), candle.open),
                    yEnd: .value(String(localized: "dashboard.candlestick.close", defaultValue: "Close"), candle.close),
                    width: .fixed(8)
                )
                .foregroundStyle(candle.close >= candle.open ? .green : .red)
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxisLabel(widget.metric.unit)
            .modifier(DashboardMetricScale(widget: widget))
        }
    }
}

private struct DashboardStateTimeline: View {
    let cells: [TelemetryHeatmapCell]

    var body: some View {
        if cells.isEmpty {
            DashboardNoData()
        } else {
            Chart(cells) { cell in
                RectangleMark(
                    x: .value(String(localized: "Day"), cell.dayIndex),
                    y: .value(String(localized: "Hour"), cell.hour)
                )
                .foregroundStyle(cell.value > 0 ? Color.green : Color.secondary.opacity(0.12))
            }
            .chartXAxisLabel("Tag im Zeitraum")
            .chartYAxisLabel("Stunde")
            .chartYScale(domain: 0...23)
        }
    }
}

private struct DashboardRanking: View {
    let widget: TelemetryDashboardWidget
    let snapshot: TelemetryDashboardSnapshot
    let nodeNames: [UInt32: String]

    private var ranking: [(nodeId: UInt32, value: Double)] {
        snapshot.latestByNode.map { ($0.key, $0.value.value) }.sorted { $0.value > $1.value }
    }

    var body: some View {
        if ranking.isEmpty {
            DashboardNoData()
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(ranking.enumerated()), id: \.element.nodeId) { index, row in
                        HStack {
                            Text("\(index + 1)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(index < 3 ? Color.orange : Color.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(
                                nodeNames[row.nodeId]
                                    ?? TelemetryDashboardNode.fallbackName(for: row.nodeId)
                            )
                                .lineLimit(1)
                            Spacer()
                            Text(row.value, format: .number.precision(.fractionLength(1)))
                                .font(.body.monospacedDigit())
                            Text(widget.metric.unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(index.isMultiple(of: 2) ? Color.secondary.opacity(0.06) : .clear)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct DashboardMultiStat: View {
    let widget: TelemetryDashboardWidget
    let snapshot: TelemetryDashboardSnapshot
    let nodeNames: [UInt32: String]

    private var groups: [(nodeId: UInt32, points: [TelemetrySeriesPoint])] {
        snapshot.valuesByNode.map { ($0.key, $0.value) }.sorted {
            (nodeNames[$0.nodeId] ?? "") < (nodeNames[$1.nodeId] ?? "")
        }
    }

    var body: some View {
        if groups.isEmpty {
            DashboardNoData()
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(groups, id: \.nodeId) { group in
                        let sorted = group.points.sorted { $0.timestamp < $1.timestamp }
                        let values = sorted.map(\.value)
                        VStack(spacing: 5) {
                            Text(
                                nodeNames[group.nodeId]
                                    ?? TelemetryDashboardNode.fallbackName(for: group.nodeId)
                            )
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text(sorted.last?.value ?? 0, format: .number.precision(.fractionLength(1)))
                                .font(.title2.monospacedDigit().weight(.light))
                            HStack(spacing: 6) {
                                MiniValue(label: "↓", value: values.min() ?? 0)
                                MiniValue(label: "Ø", value: values.reduce(0, +) / Double(values.count))
                                MiniValue(label: "↑", value: values.max() ?? 0)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.18))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct DashboardMeshHealth: View {
    let snapshot: TelemetryDashboardSnapshot
    let nodeNames: [UInt32: String]

    var body: some View {
        if let health = snapshot.health {
            ScrollView {
                VStack(spacing: 9) {
                    HStack(spacing: 8) {
                        HealthStateIndicator(state: health.state, size: 14)
                        Text("Mesh-Score")
                            .font(.headline)
                        Text(health.score, format: .number.precision(.fractionLength(0)))
                            .font(.title3.monospacedDigit().bold())
                        Text("%")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(9)
                    .background(health.state.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 6) {
                        HealthFactor(
                            label: String(localized: "Reception"),
                            value: health.receptionScore * 100,
                            unit: "%"
                        )
                        HealthFactor(
                            label: String(localized: "Channel"),
                            value: health.channelUtilization,
                            unit: "%"
                        )
                        HealthFactor(
                            label: String(localized: "Path"),
                            value: health.averagePathCost,
                            unit: "Hops"
                        )
                        HealthFactor(
                            label: String(localized: "Packets"),
                            value: Double(health.packetCount),
                            unit: ""
                        )
                    }

                    ForEach(snapshot.healthByNode.keys.sorted(), id: \.self) { nodeId in
                        if let nodeHealth = snapshot.healthByNode[nodeId] {
                            HStack(spacing: 8) {
                                HealthStateIndicator(state: nodeHealth.state, size: 10)
                                Text(
                                    nodeNames[nodeId]
                                        ?? TelemetryDashboardNode.fallbackName(for: nodeId)
                                )
                                    .lineLimit(1)
                                Spacer()
                                Text(nodeHealth.score, format: .number.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit().bold())
                                Text("%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(nodeHealth.state.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        } else {
            DashboardNoData()
        }
    }
}

private struct DashboardClock: View {
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    var body: some View {
        TimelineView(PeriodicTimelineSchedule(from: Date(), by: 1)) { context in
            VStack(spacing: 8) {
                Text(context.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: 46, weight: .light, design: .monospaced))
                    .monospacedDigit()
                Text("UTC  \(Self.utcFormatter.string(from: context.date))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Lokale Zeit und UTC-Zeit")
        }
    }
}

private struct DashboardNoData: View {
    var body: some View {
        ContentUnavailableView(
            "Keine Daten",
            systemImage: "chart.xyaxis.line",
            description: Text("Für Nodes, Metrik und Zeitraum liegen keine Messwerte vor.")
        )
    }
}

private struct MiniValue: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit())
        }
    }
}

private struct HealthFactor: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit().bold())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

private struct HealthStateIndicator: View {
    let state: TelemetryHealthState
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .shadow(color: state.color.opacity(0.55), radius: 4)
            .accessibilityLabel(state.accessibilityLabel)
    }
}

private struct DashboardMetricScale: ViewModifier {
    let widget: TelemetryDashboardWidget

    @ViewBuilder
    func body(content: Content) -> some View {
        if let range = widget.effectiveDisplayRange {
            content.chartYScale(domain: range)
        } else {
            content
        }
    }
}

private struct DashboardHistogramScale: ViewModifier {
    let widget: TelemetryDashboardWidget

    @ViewBuilder
    func body(content: Content) -> some View {
        if let range = widget.effectiveDisplayRange {
            content.chartXScale(domain: range)
        } else {
            content
        }
    }
}

private struct DashboardAggregateKey: Hashable {
    let nodeId: UInt32
    let date: Date
}

private struct DashboardAggregatePoint: Identifiable {
    var id: String { "\(nodeId)-\(date.timeIntervalSince1970)" }
    let nodeId: UInt32
    let date: Date
    let value: Double
}

private extension TelemetryHealthState {
    var color: Color {
        switch self {
        case .noData: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .alert: return .red
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .noData: return String(localized: "No Data")
        case .good: return String(localized: "Good")
        case .warning: return String(localized: "Warning")
        case .alert: return String(localized: "Alert")
        }
    }
}
