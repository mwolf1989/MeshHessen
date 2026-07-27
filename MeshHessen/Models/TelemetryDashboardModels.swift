import Foundation

/// A node available to dashboard widgets, including database-only nodes that do
/// not currently have a live `NodeInfo` object.
struct TelemetryDashboardNode: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String

    var displayID: String {
        String(format: "!%08x", id)
    }

    static func fallbackName(for nodeID: UInt32) -> String {
        String(format: "!%08x", nodeID)
    }
}

/// Builds the dashboard node picker from every durable and live source without
/// coupling the selection rules to SwiftUI.
enum TelemetryDashboardNodeCatalog {
    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    static func nodes(
        liveNodeNames: [UInt32: String],
        databaseNodeIDs: [UInt32],
        storedWidgetNodeIDs: [UInt32]
    ) -> [TelemetryDashboardNode] {
        let nodeIDs = Set(liveNodeNames.keys)
            .union(databaseNodeIDs)
            .union(storedWidgetNodeIDs)

        return nodeIDs.map { nodeID in
            let liveName = liveNodeNames[nodeID]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if let liveName, !liveName.isEmpty {
                name = liveName
            } else {
                name = TelemetryDashboardNode.fallbackName(for: nodeID)
            }
            return TelemetryDashboardNode(
                id: nodeID,
                name: name
            )
        }
        .sorted(by: areInIncreasingOrder)
    }

    static func filtered(
        _ nodes: [TelemetryDashboardNode],
        query: String
    ) -> [TelemetryDashboardNode] {
        let normalizedQuery = normalized(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedQuery.isEmpty else { return nodes }
        return nodes.filter { node in
            normalized(node.name).contains(normalizedQuery)
                || normalized(node.displayID).contains(normalizedQuery)
        }
    }

    static func namesByID(_ nodes: [TelemetryDashboardNode]) -> [UInt32: String] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.name) })
    }

    private static func areInIncreasingOrder(
        _ lhs: TelemetryDashboardNode,
        _ rhs: TelemetryDashboardNode
    ) -> Bool {
        let lhsName = normalized(lhs.name)
        let rhsName = normalized(rhs.name)
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.id < rhs.id
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: comparisonLocale
        )
    }
}

enum TelemetryDashboardWidgetType: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case line
    case area
    case bar
    case scatter
    case gauge
    case stat
    case heatmap
    case histogram
    case candlestick
    case stateline
    case ranking
    case multistat
    case meshhealth
    case clock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .line: return String(localized: "Line")
        case .area: return String(localized: "Area")
        case .bar: return String(localized: "Bar")
        case .scatter: return String(localized: "Scatter Plot")
        case .gauge: return String(localized: "Gauge")
        case .stat: return String(localized: "Statistic")
        case .heatmap: return String(localized: "Heatmap")
        case .histogram: return String(localized: "Histogram")
        case .candlestick: return String(localized: "Candlestick")
        case .stateline: return String(localized: "Activity Timeline")
        case .ranking: return String(localized: "Ranking")
        case .multistat: return String(localized: "Multi-Stat")
        case .meshhealth: return String(localized: "Mesh Health")
        case .clock: return String(localized: "Clock")
        }
    }

    var systemImage: String {
        switch self {
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.xyaxis.line"
        case .bar: return "chart.bar"
        case .scatter: return "chart.dots.scatter"
        case .gauge: return "gauge.with.dots.needle.50percent"
        case .stat: return "number.square"
        case .heatmap: return "square.grid.3x3.fill"
        case .histogram: return "chart.bar.xaxis"
        case .candlestick: return "chart.bar.doc.horizontal"
        case .stateline: return "timeline.selection"
        case .ranking: return "list.number"
        case .multistat: return "square.grid.2x2"
        case .meshhealth: return "heart.text.square"
        case .clock: return "clock"
        }
    }

    var allowsMultipleNodes: Bool {
        switch self {
        case .line, .area, .bar, .scatter, .ranking, .multistat, .meshhealth:
            return true
        default:
            return false
        }
    }

    var usesMetric: Bool { self != .clock && self != .meshhealth }

    var supportsChartOptions: Bool { self == .line || self == .area }
}

struct TelemetryDashboardWidget: Identifiable, Codable, Hashable, Sendable {
    static let minimumWidth = 280.0
    static let minimumHeight = 200.0

    var id: UUID
    var type: TelemetryDashboardWidgetType
    var metric: TelemetrySeriesMetric
    var nodeIds: [UInt32]
    var days: Int
    var title: String
    var width: Double
    var height: Double
    var threshold: Double?
    var showMovingAverage: Bool

    init(
        id: UUID = UUID(),
        type: TelemetryDashboardWidgetType = .line,
        metric: TelemetrySeriesMetric = .snr,
        nodeIds: [UInt32] = [],
        days: Int = 7,
        title: String = "",
        width: Double = 420,
        height: Double = 300,
        threshold: Double? = nil,
        showMovingAverage: Bool = false
    ) {
        self.id = id
        self.type = type
        self.metric = metric
        self.nodeIds = Array(Set(nodeIds)).sorted()
        self.days = Self.validDays(days)
        self.title = title
        self.width = max(Self.minimumWidth, width)
        self.height = max(Self.minimumHeight, height)
        self.threshold = threshold?.isFinite == true ? threshold : nil
        self.showMovingAverage = showMovingAverage
    }

    var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if type == .clock || type == .meshhealth { return type.displayName }
        return metric.displayName
    }

    var effectiveDays: Int { days > 0 ? days : 36_500 }

    /// Resolves an empty multi-node selection dynamically, while leaving empty
    /// single-node selections invalid instead of silently choosing a node.
    func resolvedNodeIDs(knownNodeIDs: [UInt32]) -> [UInt32] {
        if nodeIds.isEmpty, type.allowsMultipleNodes {
            return Array(Set(knownNodeIDs)).sorted()
        }
        return nodeIds
    }

    mutating func normalize() {
        nodeIds = Array(Set(nodeIds)).sorted()
        days = Self.validDays(days)
        width = max(Self.minimumWidth, width.isFinite ? width : 420)
        height = max(Self.minimumHeight, height.isFinite ? height : 300)
        if threshold?.isFinite != true { threshold = nil }
        if !type.allowsMultipleNodes, let first = nodeIds.first { nodeIds = [first] }
        if !type.supportsChartOptions { showMovingAverage = false }
    }

    private static func validDays(_ value: Int) -> Int {
        [0, 1, 7, 14, 30, 90].contains(value) ? value : 7
    }
}

struct TelemetryDashboard: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var widgets: [TelemetryDashboardWidget]

    init(id: UUID = UUID(), name: String, widgets: [TelemetryDashboardWidget] = []) {
        self.id = id
        self.name = name
        self.widgets = widgets
    }

    mutating func normalize() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? String(localized: "Dashboard") : String(trimmed.prefix(80))
        var seen = Set<UUID>()
        widgets = widgets.compactMap { widget in
            var normalized = widget
            if seen.contains(normalized.id) { normalized.id = UUID() }
            seen.insert(normalized.id)
            normalized.normalize()
            return normalized
        }
    }
}

enum TelemetryDashboardLayoutEngine {
    /// Packs widgets into deterministic rows while respecting their configured width.
    static func rows(
        widgets: [TelemetryDashboardWidget],
        availableWidth: Double,
        spacing: Double = 12
    ) -> [[UUID]] {
        guard !widgets.isEmpty else { return [] }
        let usableWidth = max(TelemetryDashboardWidget.minimumWidth, availableWidth)
        var result: [[UUID]] = []
        var row: [UUID] = []
        var used = 0.0

        for widget in widgets {
            let width = min(usableWidth, max(TelemetryDashboardWidget.minimumWidth, widget.width))
            let required = row.isEmpty ? width : width + spacing
            if !row.isEmpty, used + required > usableWidth {
                result.append(row)
                row = []
                used = 0
            }
            row.append(widget.id)
            used += row.count == 1 ? width : width + spacing
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
}
