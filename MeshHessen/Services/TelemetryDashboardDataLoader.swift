import Foundation

struct TelemetryDashboardSnapshot: Sendable {
    var series: [TelemetrySeriesPoint] = []
    var heatmap: [TelemetryHeatmapCell] = []
    var histogram: [TelemetryHistogramBin] = []
    var candles: [TelemetryCandlePoint] = []
    var health: TelemetryMeshHealthSummary?
    var healthByNode: [UInt32: TelemetryMeshHealthSummary] = [:]

    var valuesByNode: [UInt32: [TelemetrySeriesPoint]] {
        Dictionary(grouping: series, by: \.nodeId)
    }

    var latestByNode: [UInt32: TelemetrySeriesPoint] {
        valuesByNode.compactMapValues { points in
            points.max(by: { $0.timestamp < $1.timestamp })
        }
    }
}

struct TelemetryDashboardDataLoader: Sendable {
    let database: TelemetryDatabaseService

    func load(
        widget: TelemetryDashboardWidget,
        fallbackNodeIds: [UInt32]
    ) async -> TelemetryDashboardSnapshot {
        let database = database
        return await Task.detached(priority: .utility) {
            let nodeIds = widget.nodeIds.isEmpty ? fallbackNodeIds : widget.nodeIds
            var snapshot = TelemetryDashboardSnapshot()
            switch widget.type {
            case .clock:
                break
            case .meshhealth:
                snapshot.health = database.getMeshHealthSummary(
                    nodeIds: nodeIds,
                    days: widget.effectiveDays
                )
                for nodeId in nodeIds {
                    snapshot.healthByNode[nodeId] = database.getMeshHealthSummary(
                        nodeIds: [nodeId],
                        days: widget.effectiveDays
                    )
                }
            case .heatmap:
                if let nodeId = nodeIds.first {
                    snapshot.series = database.getTimeSeries(
                        nodeIds: [nodeId],
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                    snapshot.heatmap = database.getHeatmapData(
                        nodeId: nodeId,
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                }
            case .stateline:
                if let nodeId = nodeIds.first {
                    snapshot.series = database.getTimeSeries(
                        nodeIds: [nodeId],
                        metric: .packetCount,
                        days: widget.days > 0 ? widget.days : 14
                    )
                    snapshot.heatmap = database.getNodeActivityGrid(
                        nodeId: nodeId,
                        days: widget.days > 0 ? widget.days : 14
                    )
                }
            case .histogram:
                if let nodeId = nodeIds.first {
                    snapshot.series = database.getTimeSeries(
                        nodeIds: [nodeId],
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                    snapshot.histogram = database.getHistogram(
                        nodeId: nodeId,
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                }
            case .candlestick:
                if let nodeId = nodeIds.first {
                    snapshot.series = database.getTimeSeries(
                        nodeIds: [nodeId],
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                    snapshot.candles = database.getCandlestickData(
                        nodeId: nodeId,
                        metric: widget.metric,
                        days: widget.effectiveDays
                    )
                }
            default:
                snapshot.series = database.getTimeSeries(
                    nodeIds: nodeIds,
                    metric: widget.metric,
                    days: widget.effectiveDays
                )
            }
            return snapshot
        }.value
    }

    func csv(
        widget: TelemetryDashboardWidget,
        snapshot: TelemetryDashboardSnapshot,
        nodeNames: [UInt32: String]
    ) -> String {
        var rows = ["node_id,node_name,timestamp,metric,value,unit"]
        let formatter = ISO8601DateFormatter()
        for point in snapshot.series.sorted(by: { $0.timestamp < $1.timestamp }) {
            let nodeName = Self.escapeCSV(nodeNames[point.nodeId] ?? "!\(String(point.nodeId, radix: 16))")
            rows.append([
                String(point.nodeId),
                nodeName,
                formatter.string(from: point.timestamp),
                widget.metric.rawValue,
                String(format: "%.6f", point.value),
                Self.escapeCSV(widget.metric.unit),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
