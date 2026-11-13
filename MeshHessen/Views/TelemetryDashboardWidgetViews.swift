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
        .background(cardZoneColor?.opacity(hasActiveAlarm ? 0.08 : 0.05) ?? Color.clear)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    cardZoneColor ?? Color.secondary.opacity(0.2),
                    lineWidth: cardZoneColor == nil ? 1 : 2
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
            knownNodeIDs: nodeNames.keys.sorted(),
            radiationInSievert: SettingsService.shared.radiationInSievert
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
                    .foregroundStyle(cardZoneColor ?? .red)
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

    /// The most severe non-ok zone among the latest value of every node.
    private var alarmReading: (zone: TelemetryZone, point: TelemetrySeriesPoint)? {
        guard widget.hasZones else { return nil }
        var worst: (zone: TelemetryZone, point: TelemetrySeriesPoint)?
        for point in snapshot.latestByNode.values.sorted(by: { $0.nodeId < $1.nodeId }) {
            let zone = widget.zone(for: point.value)
            if zone.severity > (worst?.zone.severity ?? 0) { worst = (zone, point) }
        }
        return worst
    }

    private var hasActiveAlarm: Bool { alarmReading?.zone.isAlarm == true }

    private var cardZoneColor: Color? {
        guard let alarmReading else { return nil }
        return alarmReading.zone.isAlarm ? .red : .orange
    }

    private func alarmDescription(
        for reading: (zone: TelemetryZone, point: TelemetrySeriesPoint)
    ) -> String {
        let node = nodeNames[reading.point.nodeId]
            ?? TelemetryDashboardNode.fallbackName(for: reading.point.nodeId)
        switch reading.zone {
        case .alarmLow:
            return String(localized: "\(node) is at or below the alarm limit")
        case .alarmHigh:
            return String(localized: "\(node) is at or above the alarm limit")
        case .warnLow:
            return String(localized: "\(node) is at or below the warning limit")
        case .warnHigh:
            return String(localized: "\(node) is at or above the warning limit")
        case .ok:
            return String(localized: "\(node) is within the normal range")
        }
    }

    private func load() async {
        guard widget.type != .clock else { return }
        isLoading = true
        let loaded = await loader.load(
            widget: widget,
            fallbackNodeIds: nodeNames.keys.sorted(),
            radiationInSievert: SettingsService.shared.radiationInSievert
        )
        guard !Task.isCancelled else { return }
        snapshot = loaded
        isLoading = false
    }

    private struct LoadKey: Hashable {
        let widget: TelemetryDashboardWidget
        let refreshToken: Int
        let knownNodeIDs: [UInt32]
        let radiationInSievert: Bool
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
            let zoneLayout = self.zoneLayout
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
                if let zoneLayout {
                    DashboardZoneMarks(layout: zoneLayout, valueAxis: .vertical)
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
            .modifier(DashboardMetricScale(widget: widget, zoneLayout: zoneLayout))
        }
    }

    private var zoneLayout: TelemetryZoneLayout? {
        TelemetryZoneLayout(widget: widget, values: points.map(\.value))
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
            let aggregates = self.aggregates
            let zoneLayout = TelemetryZoneLayout(
                widget: widget,
                values: aggregates.map(\.value),
                includeZero: true
            )
            Chart {
                ForEach(aggregates) { point in
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
                if let zoneLayout {
                    DashboardZoneMarks(layout: zoneLayout, valueAxis: .vertical)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .modifier(DashboardMetricScale(widget: widget, zoneLayout: zoneLayout))
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
            let zoneLayout = TelemetryZoneLayout(widget: widget, values: points.map(\.value))
            Chart {
                ForEach(points) { point in
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
                if let zoneLayout {
                    DashboardZoneMarks(layout: zoneLayout, valueAxis: .vertical)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .modifier(DashboardMetricScale(widget: widget, zoneLayout: zoneLayout))
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
        if let configured = widget.displayedEffectiveRange { return configured }
        let values = points.map(\.value)
        let minimum = min(0, values.min() ?? 0)
        let maximum = values.max() ?? 1
        return minimum...(maximum > minimum ? maximum : minimum + 1)
    }

    var body: some View {
        if let latest {
            let range = self.range
            let zoneColor = widget.zoneColor(for: latest.value)
            VStack(spacing: 8) {
                DashboardZoneDial(
                    value: latest.value,
                    range: range,
                    segments: widget.zoneSegments(in: range),
                    tint: zoneColor ?? .accentColor,
                    valueColor: zoneColor ?? .primary
                )
                .frame(width: 112, height: 112)
                .padding(12)
                .accessibilityLabel(widget.metric.displayName)
                .accessibilityValue(Text(latest.value, format: .number.precision(.fractionLength(1))))

                Text(widget.displayUnit)
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
                    .foregroundStyle(widget.zoneColor(for: latest.value) ?? .primary)
                Text(widget.displayUnit)
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
        if let range = widget.explicitDisplayRange {
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
            let zoneLayout = TelemetryZoneLayout(
                widget: widget,
                values: bins.flatMap { [$0.lowerBound, $0.upperBound] }
            )
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        xStart: .value(String(localized: "From"), bin.lowerBound),
                        xEnd: .value(String(localized: "To"), bin.upperBound),
                        y: .value(String(localized: "Count"), bin.count)
                    )
                    .foregroundStyle(.green.gradient)
                }
                if let zoneLayout {
                    DashboardZoneMarks(layout: zoneLayout, valueAxis: .horizontal)
                }
            }
            .chartXAxisLabel(widget.displayUnit)
            .chartYAxisLabel("Messungen")
            .modifier(DashboardHistogramScale(widget: widget, zoneLayout: zoneLayout))
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
            let zoneLayout = TelemetryZoneLayout(
                widget: widget,
                values: candles.flatMap { [$0.low, $0.high] }
            )
            Chart {
                if let zoneLayout {
                    DashboardZoneMarks(layout: zoneLayout, valueAxis: .vertical)
                }
                ForEach(candles) { candle in
                    RuleMark(
                        x: .value(String(localized: "Day"), candle.date, unit: .day),
                        yStart: .value(String(localized: "Low"), candle.low),
                        yEnd: .value(String(localized: "High"), candle.high)
                    )
                    .foregroundStyle(color(for: candle))
                    RectangleMark(
                        x: .value(String(localized: "Day"), candle.date, unit: .day),
                        yStart: .value(String(localized: "dashboard.candlestick.open", defaultValue: "Open"), candle.open),
                        yEnd: .value(String(localized: "dashboard.candlestick.close", defaultValue: "Close"), candle.close),
                        width: .fixed(8)
                    )
                    .foregroundStyle(color(for: candle))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxisLabel(widget.displayUnit)
            .modifier(DashboardMetricScale(widget: widget, zoneLayout: zoneLayout))
        }
    }

    /// Candles whose body is under 2 % of their range are noise, not a rise or fall.
    private func color(for candle: TelemetryCandlePoint) -> Color {
        let body = abs(candle.close - candle.open)
        let span = max(abs(candle.high - candle.low), .leastNonzeroMagnitude)
        if body < 0.02 * span { return .secondary }
        return candle.close >= candle.open ? .green : .red
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
                            Text(widget.displayUnit)
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

/// With zones the domain comes from the zone layout (data plus bounds), so the
/// alarm bands end exactly at the plot edge; otherwise charts auto-scale unless
/// the user set a display range.
private struct DashboardMetricScale: ViewModifier {
    let widget: TelemetryDashboardWidget
    let zoneLayout: TelemetryZoneLayout?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let range = zoneLayout?.domain ?? widget.explicitDisplayRange {
            content.chartYScale(domain: range)
        } else {
            content
        }
    }
}

private struct DashboardHistogramScale: ViewModifier {
    let widget: TelemetryDashboardWidget
    let zoneLayout: TelemetryZoneLayout?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let range = zoneLayout?.domain ?? widget.explicitDisplayRange {
            content.chartXScale(domain: range)
        } else {
            content
        }
    }
}

// MARK: - Zones

/// Warn (orange) and alarm (red) rule lines plus translucent red bands beyond
/// each alarm bound. `valueAxis` is the axis that carries the metric.
private struct DashboardZoneMarks: ChartContent {
    let layout: TelemetryZoneLayout
    let valueAxis: Axis

    var body: some ChartContent {
        if valueAxis == .vertical {
            ForEach(Array(layout.alarmBands.enumerated()), id: \.offset) { _, band in
                RectangleMark(
                    yStart: .value(String(localized: "Alarm zone"), band.lowerBound),
                    yEnd: .value(String(localized: "Alarm zone"), band.upperBound)
                )
                .foregroundStyle(Color.red.opacity(0.1))
            }
            ForEach(layout.warnLines, id: \.self) { bound in
                RuleMark(y: .value(String(localized: "Warning limit"), bound))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(layout.alarmLines, id: \.self) { bound in
                RuleMark(y: .value(String(localized: "Alarm limit"), bound))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        } else {
            ForEach(Array(layout.alarmBands.enumerated()), id: \.offset) { _, band in
                RectangleMark(
                    xStart: .value(String(localized: "Alarm zone"), band.lowerBound),
                    xEnd: .value(String(localized: "Alarm zone"), band.upperBound)
                )
                .foregroundStyle(Color.red.opacity(0.1))
            }
            ForEach(layout.warnLines, id: \.self) { bound in
                RuleMark(x: .value(String(localized: "Warning limit"), bound))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(layout.alarmLines, id: \.self) { bound in
                RuleMark(x: .value(String(localized: "Alarm limit"), bound))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
        }
    }
}

/// A 270° gauge dial with the value arc inside and an outer ring that marks the
/// ok, warn and alarm ranges of the scale.
private struct DashboardZoneDial: View {
    let value: Double
    let range: ClosedRange<Double>
    let segments: [TelemetryZoneSegment]
    let tint: Color
    let valueColor: Color

    private static let sweep = 0.75
    private static let trackWidth: CGFloat = 10
    private static let ringWidth: CGFloat = 4
    private static let ringGap: CGFloat = 4

    var body: some View {
        ZStack {
            ZStack {
                arc(from: range.lowerBound, to: range.upperBound)
                    .stroke(Color.secondary.opacity(0.2), style: trackStyle)
                arc(from: range.lowerBound, to: value)
                    .stroke(tint, style: trackStyle)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    arc(from: segment.range.lowerBound, to: segment.range.upperBound)
                        .stroke(segment.zone.color, style: StrokeStyle(lineWidth: Self.ringWidth))
                        .padding(-(Self.trackWidth + Self.ringWidth) / 2 - Self.ringGap)
                }
            }
            .rotationEffect(.degrees(135))

            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.title2.monospacedDigit())
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, Self.trackWidth + 4)

            VStack {
                Spacer()
                HStack {
                    Text(range.lowerBound, format: .number.precision(.fractionLength(0)))
                    Spacer()
                    Text(range.upperBound, format: .number.precision(.fractionLength(0)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var trackStyle: StrokeStyle {
        StrokeStyle(lineWidth: Self.trackWidth, lineCap: .round)
    }

    private func arc(from start: Double, to end: Double) -> some Shape {
        Circle().trim(
            from: fraction(start) * Self.sweep,
            to: max(fraction(start), fraction(end)) * Self.sweep
        )
    }

    private func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }
}

private extension TelemetryZone {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warnLow, .warnHigh: return .orange
        case .alarmLow, .alarmHigh: return .red
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

// MARK: - Display Units

private extension TelemetryDashboardWidget {
    /// Unit matching the converted values in `TelemetryDashboardSnapshot`.
    var displayUnit: String {
        metric.displayUnit(radiationInSievert: SettingsService.shared.radiationInSievert)
    }

    /// User-entered ranges are already in the displayed unit; the metric's suggested
    /// range is stored in the base unit and converted here.
    var displayedEffectiveRange: ClosedRange<Double>? {
        explicitDisplayRange
            ?? metric.displaySuggestedRange(radiationInSievert: SettingsService.shared.radiationInSievert)
    }

    /// Zone colour for a displayed value, or nil (neutral) when no bounds are set.
    func zoneColor(for value: Double) -> Color? {
        hasZones ? zone(for: value).color : nil
    }
}
