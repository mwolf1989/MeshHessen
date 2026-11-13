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

    var supportsDisplayRange: Bool {
        switch self {
        case .line, .area, .bar, .scatter, .gauge, .heatmap, .histogram, .candlestick:
            return true
        default:
            return false
        }
    }
}

// MARK: - Warn / Alarm Zones

/// Zone of a value relative to a widget's warn and alarm bounds (Windows `AlarmZone`).
enum TelemetryZone: String, Codable, Hashable, Sendable {
    case ok
    case warnLow
    case warnHigh
    case alarmLow
    case alarmHigh

    /// 0 = ok, 1 = warn, 2 = alarm.
    var severity: Int {
        switch self {
        case .ok: return 0
        case .warnLow, .warnHigh: return 1
        case .alarmLow, .alarmHigh: return 2
        }
    }

    var isAlarm: Bool { severity == 2 }
    var isWarning: Bool { severity == 1 }
}

enum TelemetryAlarmEvaluator {
    /// Classifies a value. Bounds are inclusive and alarm bounds win over warn bounds;
    /// nil or non-finite bounds are ignored and a non-finite value is always `.ok`.
    static func zone(
        value: Double,
        warnMinimum: Double?,
        warnMaximum: Double?,
        alarmMinimum: Double?,
        alarmMaximum: Double?
    ) -> TelemetryZone {
        guard value.isFinite else { return .ok }
        if let alarmMinimum, alarmMinimum.isFinite, value <= alarmMinimum { return .alarmLow }
        if let alarmMaximum, alarmMaximum.isFinite, value >= alarmMaximum { return .alarmHigh }
        if let warnMinimum, warnMinimum.isFinite, value <= warnMinimum { return .warnLow }
        if let warnMaximum, warnMaximum.isFinite, value >= warnMaximum { return .warnHigh }
        return .ok
    }

    /// Every zone change notifies: entering warn, entering alarm and recovering to ok.
    static func shouldNotify(previous: TelemetryZone, current: TelemetryZone) -> Bool {
        previous != current
    }
}

/// A coloured range on a gauge scale. Segments are listed in painting order
/// (ok first, then warn, then alarm), so later segments cover earlier ones.
struct TelemetryZoneSegment: Hashable, Sendable {
    let zone: TelemetryZone
    let range: ClosedRange<Double>
}

/// Rule lines, alarm bands and the value-axis domain for a chart with zones.
struct TelemetryZoneLayout: Hashable, Sendable {
    let domain: ClosedRange<Double>
    let warnLines: [Double]
    let alarmLines: [Double]
    let alarmBands: [ClosedRange<Double>]

    /// Returns nil when the widget has no zone bounds. Without a configured display
    /// range the domain covers the data and every bound, padded by 5 %, so the bands
    /// can run exactly to the visible edge.
    init?(widget: TelemetryDashboardWidget, values: [Double], includeZero: Bool = false) {
        guard widget.hasZones else { return nil }
        let warnBounds = [widget.warnMinimum, widget.warnMaximum].compactMap { $0 }
        let alarmBounds = [widget.alarmMinimum, widget.alarmMaximum].compactMap { $0 }

        let domain: ClosedRange<Double>
        if let explicit = widget.explicitDisplayRange {
            domain = explicit
        } else {
            var candidates = values.filter(\.isFinite) + warnBounds + alarmBounds
            if includeZero { candidates.append(0) }
            var lower = candidates.min() ?? 0
            var upper = candidates.max() ?? 1
            if lower == upper {
                lower -= 1
                upper += 1
            }
            let padding = (upper - lower) * 0.05
            if !(includeZero && lower == 0) { lower -= padding }
            if !(includeZero && upper == 0) { upper += padding }
            domain = lower...upper
        }

        var bands: [ClosedRange<Double>] = []
        if let minimum = widget.alarmMinimum, minimum > domain.lowerBound {
            bands.append(domain.lowerBound...min(minimum, domain.upperBound))
        }
        if let maximum = widget.alarmMaximum, maximum < domain.upperBound {
            bands.append(max(maximum, domain.lowerBound)...domain.upperBound)
        }

        self.domain = domain
        self.warnLines = warnBounds.filter { domain.contains($0) }
        self.alarmLines = alarmBounds.filter { domain.contains($0) }
        self.alarmBands = bands
    }
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
    /// Legacy single threshold. Migrated to `alarmMaximum` on decode when no zone
    /// bounds are set; no longer edited or drawn.
    var threshold: Double?
    var displayMinimum: Double?
    var displayMaximum: Double?
    /// Zone bounds are in the metric's displayed unit (see `displayValue`).
    var warnMinimum: Double?
    var warnMaximum: Double?
    var alarmMinimum: Double?
    var alarmMaximum: Double?
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
        displayMinimum: Double? = nil,
        displayMaximum: Double? = nil,
        warnMinimum: Double? = nil,
        warnMaximum: Double? = nil,
        alarmMinimum: Double? = nil,
        alarmMaximum: Double? = nil,
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
        self.displayMinimum = displayMinimum
        self.displayMaximum = displayMaximum
        self.warnMinimum = warnMinimum
        self.warnMaximum = warnMaximum
        self.alarmMinimum = alarmMinimum
        self.alarmMaximum = alarmMaximum
        self.showMovingAverage = showMovingAverage
        normalizeRanges()
    }

    var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if type == .clock || type == .meshhealth { return type.displayName }
        return metric.displayName
    }

    var effectiveDays: Int { days > 0 ? days : 36_500 }

    var displayRange: ClosedRange<Double>? {
        guard let displayMinimum,
              let displayMaximum,
              displayMinimum.isFinite,
              displayMaximum.isFinite,
              displayMinimum < displayMaximum else {
            return nil
        }
        return displayMinimum...displayMaximum
    }

    /// The axis range the user configured, without the metric's suggested fallback.
    /// Charts apply only this range and otherwise scale to the drawn data. A single
    /// bound does not form a usable range (`normalize()` drops it), so it yields nil.
    var explicitDisplayRange: ClosedRange<Double>? {
        displayRange
    }

    var effectiveDisplayRange: ClosedRange<Double>? {
        displayRange ?? metric.suggestedRange
    }

    var hasZones: Bool {
        warnMinimum != nil || warnMaximum != nil || alarmMinimum != nil || alarmMaximum != nil
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

    /// Coloured ranges for a gauge scale, in painting order; empty without zones.
    func zoneSegments(in range: ClosedRange<Double>) -> [TelemetryZoneSegment] {
        guard hasZones else { return [] }
        let candidates: [(TelemetryZone, Double?, Double?)] = [
            (.ok, range.lowerBound, range.upperBound),
            (.warnLow, range.lowerBound, warnMinimum),
            (.warnHigh, warnMaximum, range.upperBound),
            (.alarmLow, range.lowerBound, alarmMinimum),
            (.alarmHigh, alarmMaximum, range.upperBound),
        ]
        return candidates.compactMap { zone, start, end in
            guard let start, let end else { return nil }
            let lower = max(start, range.lowerBound)
            let upper = min(end, range.upperBound)
            guard lower < upper else { return nil }
            return TelemetryZoneSegment(zone: zone, range: lower...upper)
        }
    }

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
        normalizeRanges()
        if !type.allowsMultipleNodes, let first = nodeIds.first { nodeIds = [first] }
        if !type.supportsChartOptions { showMovingAverage = false }
    }

    private mutating func normalizeRanges() {
        if let displayMinimum,
           let displayMaximum,
           displayMinimum.isFinite,
           displayMaximum.isFinite,
           displayMinimum < displayMaximum {
            // Keep the valid custom range.
        } else {
            displayMinimum = nil
            displayMaximum = nil
        }

        if warnMinimum?.isFinite != true { warnMinimum = nil }
        if warnMaximum?.isFinite != true { warnMaximum = nil }
        if let warnMinimum, let warnMaximum, warnMinimum >= warnMaximum {
            self.warnMinimum = nil
            self.warnMaximum = nil
        }
        if alarmMinimum?.isFinite != true { alarmMinimum = nil }
        if alarmMaximum?.isFinite != true { alarmMaximum = nil }
        if let alarmMinimum, let alarmMaximum, alarmMinimum >= alarmMaximum {
            self.alarmMinimum = nil
            self.alarmMaximum = nil
        }
    }

    /// Windows parity: a legacy single threshold acted as a high alarm.
    private mutating func migrateLegacyThreshold() {
        guard let threshold, !hasZones else { return }
        alarmMaximum = threshold
        self.threshold = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case metric
        case nodeIds
        case days
        case title
        case width
        case height
        case threshold
        case displayMinimum
        case displayMaximum
        case warnMinimum
        case warnMaximum
        case alarmMinimum
        case alarmMaximum
        case showMovingAverage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            type: try container.decodeIfPresent(TelemetryDashboardWidgetType.self, forKey: .type) ?? .line,
            metric: try container.decodeIfPresent(TelemetrySeriesMetric.self, forKey: .metric) ?? .snr,
            nodeIds: try container.decodeIfPresent([UInt32].self, forKey: .nodeIds) ?? [],
            days: try container.decodeIfPresent(Int.self, forKey: .days) ?? 7,
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 420,
            height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 300,
            threshold: try container.decodeIfPresent(Double.self, forKey: .threshold),
            displayMinimum: try container.decodeIfPresent(Double.self, forKey: .displayMinimum),
            displayMaximum: try container.decodeIfPresent(Double.self, forKey: .displayMaximum),
            warnMinimum: try container.decodeIfPresent(Double.self, forKey: .warnMinimum),
            warnMaximum: try container.decodeIfPresent(Double.self, forKey: .warnMaximum),
            alarmMinimum: try container.decodeIfPresent(Double.self, forKey: .alarmMinimum),
            alarmMaximum: try container.decodeIfPresent(Double.self, forKey: .alarmMaximum),
            showMovingAverage: try container.decodeIfPresent(Bool.self, forKey: .showMovingAverage) ?? false
        )
        migrateLegacyThreshold()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(metric, forKey: .metric)
        try container.encode(nodeIds, forKey: .nodeIds)
        try container.encode(days, forKey: .days)
        try container.encode(title, forKey: .title)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encodeIfPresent(threshold, forKey: .threshold)
        try container.encodeIfPresent(displayMinimum, forKey: .displayMinimum)
        try container.encodeIfPresent(displayMaximum, forKey: .displayMaximum)
        try container.encodeIfPresent(warnMinimum, forKey: .warnMinimum)
        try container.encodeIfPresent(warnMaximum, forKey: .warnMaximum)
        try container.encodeIfPresent(alarmMinimum, forKey: .alarmMinimum)
        try container.encodeIfPresent(alarmMaximum, forKey: .alarmMaximum)
        try container.encode(showMovingAverage, forKey: .showMovingAverage)
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
