import Foundation

/// Condenses a node's recent readings of one metric into a single representative value plus
/// a recency confidence (0…1). Port of the Windows `EnvironmentHeatmapBuilder`.
///
/// Older readings count less toward the value (half-life `valueHalfLifeHours`); a node whose
/// newest reading is itself old gets a lower confidence (half-life `recencyHalfLifeHours`), so
/// a sensor that stopped reporting stops dominating. The value is not normalised here.
enum EnvironmentHeatmapBuilder {
    static let valueHalfLifeHours = 12.0
    static let recencyHalfLifeHours = 24.0

    struct Reading: Equatable, Sendable {
        let value: Double
        let recency: Double
    }

    /// `samples` = (age in hours ≥ 0, value) of one node's readings; nil when empty.
    static func representative(_ samples: [(ageHours: Double, value: Double)]) -> Reading? {
        guard !samples.isEmpty else { return nil }

        let lambdaValue = log(2) / valueHalfLifeHours
        var weightSum = 0.0
        var valueSum = 0.0
        var newestAge = Double.greatestFiniteMagnitude
        for sample in samples {
            let age = max(0, sample.ageHours)
            let weight = exp(-lambdaValue * age)
            weightSum += weight
            valueSum += weight * sample.value
            newestAge = min(newestAge, age)
        }
        guard weightSum > 0 else { return nil }

        let recency = exp(-(log(2) / recencyHalfLifeHours) * newestAge)
        return Reading(value: valueSum / weightSum, recency: min(1, max(0, recency)))
    }
}

// MARK: - Stored data

/// One stored reading of a metric.
struct EnvironmentSample: Equatable, Sendable {
    let timestamp: Date
    let value: Double
}

/// Recent environment data of one node (see `TelemetryDatabaseService.latestEnvironmentPerNode`).
struct EnvironmentNodeSamples: Equatable, Sendable {
    let nodeId: UInt32
    /// Newest environment (non-virtual) reading of any metric.
    var latestTimestamp: Date?
    /// Metric key → newest stored value (virtual metrics included).
    var latestValues: [String: Double]
    /// Samples of the requested metric, oldest first.
    var samples: [EnvironmentSample]

    init(
        nodeId: UInt32,
        latestTimestamp: Date? = nil,
        latestValues: [String: Double] = [:],
        samples: [EnvironmentSample] = []
    ) {
        self.nodeId = nodeId
        self.latestTimestamp = latestTimestamp
        self.latestValues = latestValues
        self.samples = samples
    }

    var hasEnvironmentValues: Bool {
        latestValues.keys.contains { EnvironmentMetricInfo.metric(forKey: $0)?.isVirtual == false }
    }
}

/// When the value boxes next to sensor nodes are shown.
enum EnvironmentBoxMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case always
    case hover

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .always: return String(localized: "Always visible")
        case .hover: return String(localized: "On hover")
        }
    }
}

// MARK: - Overlay

/// A positioned node that may contribute to the overlay.
struct EnvironmentNodePosition: Equatable, Sendable {
    let nodeId: UInt32
    let latitude: Double
    let longitude: Double
    let title: String
}

/// Value box next to a sensor node.
struct EnvironmentValueBox: Equatable, Sendable, Identifiable {
    let nodeId: UInt32
    let latitude: Double
    let longitude: Double
    let title: String
    let lines: [String]
    let time: String

    var id: UInt32 { nodeId }
}

/// Text written on an iso-line (zone average).
struct EnvironmentLineLabel: Equatable, Sendable {
    let longitude: Double
    let latitude: Double
    let text: String
}

/// Legend of the selected metric in the displayed unit.
struct EnvironmentLegend: Equatable, Sendable {
    let title: String
    let unit: String
    let bands: [EnvironmentBand]
}

/// The interpolated colour surface plus its iso-lines.
struct EnvironmentSurface: Sendable {
    let image: EnvironmentRaster.Image
    /// "data:image/png;base64,…" for the vector map.
    let pngDataURI: String
    let contours: [EnvironmentSegment]
    let border: [EnvironmentSegment]
    let labels: [EnvironmentLineLabel]
    let legend: EnvironmentLegend
    let sensorCount: Int
}

/// Everything both map renderers need to draw the environment overlay.
struct EnvironmentOverlay: Sendable {
    /// Changes whenever the content changes; renderers redraw only on a new revision.
    let revision: Int
    let boxMode: EnvironmentBoxMode
    let boxes: [EnvironmentValueBox]
    let surface: EnvironmentSurface?
    /// Positioned nodes with environment data (the exclusion list).
    let sensorNodes: [EnvironmentNodePosition]
    /// Metric keys with data from a positioned node (the metric picker).
    let availableMetricKeys: Set<String>
}

/// Turns stored samples and node positions into an `EnvironmentOverlay` (pure; runs off the
/// main actor). Mirrors `RefreshEnvironmentData`/`PushEnvSurface` of the Windows client.
enum EnvironmentOverlayBuilder {
    static let influenceKm = 30.0
    static let historyHours = 48.0
    static let maxOpacity = 0.6
    static let minimumConfidence = 0.05
    static let labelCellDegrees = 0.12
    static let borderLevel = 0.15

    struct Options: Sendable {
        var metric: EnvironmentMetric
        var boxMode: EnvironmentBoxMode
        var showHeatmap: Bool
        var excludedNodeIds: Set<UInt32>
        var radiationInSievert: Bool
        var now: Date
        var timeZone: TimeZone = .current
    }

    static func build(
        revision: Int,
        nodes: [EnvironmentNodePosition],
        readings: [EnvironmentNodeSamples],
        options: Options
    ) -> EnvironmentOverlay {
        let positions = Dictionary(nodes.map { ($0.nodeId, $0) }, uniquingKeysWith: { first, _ in first })
        let sensors = readings.filter { positions[$0.nodeId] != nil && $0.hasEnvironmentValues }
        let sensorNodes = sensors.compactMap { positions[$0.nodeId] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        var available = Set<String>()
        for reading in readings where positions[reading.nodeId] != nil {
            available.formUnion(reading.latestValues.keys)
        }

        let active = sensors.filter { !options.excludedNodeIds.contains($0.nodeId) }
        let boxes: [EnvironmentValueBox] = options.boxMode == .off ? [] : active.compactMap { reading in
            positions[reading.nodeId].map { box(for: reading, at: $0, options: options) }
        }

        var surface: EnvironmentSurface?
        if options.showHeatmap {
            // Radio metrics are not environment telemetry: every positioned node may contribute.
            let contributing = options.metric.isVirtual
                ? readings.filter { positions[$0.nodeId] != nil && !options.excludedNodeIds.contains($0.nodeId) }
                : active
            surface = buildSurface(readings: contributing, positions: positions, options: options)
        }

        return EnvironmentOverlay(
            revision: revision,
            boxMode: options.boxMode,
            boxes: boxes,
            surface: surface,
            sensorNodes: sensorNodes,
            availableMetricKeys: available
        )
    }

    private static func box(
        for reading: EnvironmentNodeSamples,
        at position: EnvironmentNodePosition,
        options: Options
    ) -> EnvironmentValueBox {
        let lines = EnvironmentMetricInfo.environmentOnly.compactMap { metric -> String? in
            guard let value = reading.latestValues[metric.key] else { return nil }
            let text = EnvironmentMetricInfo.format(
                metric,
                storedValue: value,
                radiationInSievert: options.radiationInSievert
            )
            return "\(metric.displayName): \(text)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM. HH:mm"
        formatter.timeZone = options.timeZone
        return EnvironmentValueBox(
            nodeId: position.nodeId,
            latitude: position.latitude,
            longitude: position.longitude,
            title: position.title,
            lines: lines,
            time: reading.latestTimestamp.map(formatter.string(from:)) ?? ""
        )
    }

    private static func buildSurface(
        readings: [EnvironmentNodeSamples],
        positions: [UInt32: EnvironmentNodePosition],
        options: Options
    ) -> EnvironmentSurface? {
        let metric = options.metric
        let sievert = options.radiationInSievert
        var sensors: [EnvironmentField.Sensor] = []
        for reading in readings {
            guard let position = positions[reading.nodeId], !reading.samples.isEmpty else { continue }
            let samples = reading.samples.map { sample in
                (
                    ageHours: options.now.timeIntervalSince(sample.timestamp) / 3_600,
                    value: metric.displayValue(sample.value, radiationInSievert: sievert)
                )
            }
            guard let representative = EnvironmentHeatmapBuilder.representative(samples) else { continue }
            sensors.append(.init(
                longitude: position.longitude,
                latitude: position.latitude,
                value: representative.value,
                confidence: max(minimumConfidence, representative.recency)
            ))
        }

        guard let grid = EnvironmentField.build(sensors, influenceKm: influenceKm) else { return nil }
        let scale = metric.displayScale(radiationInSievert: sievert)
        guard let image = EnvironmentRaster.render(
            grid,
            min: scale.min,
            max: scale.max,
            maxOpacity: maxOpacity,
            bandCount: scale.bandCount
        ) else { return nil }

        let levels = scale.interiorLevels
        let contours = EnvironmentContours.build(grid, levels: levels)

        // Labels on the iso-lines: value = the warmer adjacent zone's average, thinned to
        // about one per 0.12° cell.
        let zoneAverages = EnvironmentZones.zoneAverages(
            grid,
            min: scale.min,
            step: scale.step,
            bandCount: scale.bandCount
        )
        var seen = Set<[Int]>()
        var labels: [EnvironmentLineLabel] = []
        for anchor in EnvironmentContours.lineLabelAnchors(grid, levels: levels) {
            guard anchor.warmerCell >= 0, anchor.warmerCell < zoneAverages.count,
                  !zoneAverages[anchor.warmerCell].isNaN else { continue }
            let key = [
                Int((anchor.longitude / labelCellDegrees).rounded(.down)),
                Int((anchor.latitude / labelCellDegrees).rounded(.down)),
            ]
            guard seen.insert(key).inserted else { continue }
            labels.append(.init(
                longitude: anchor.longitude,
                latitude: anchor.latitude,
                text: zoneAverages[anchor.warmerCell].formatted(
                    .number.precision(.fractionLength(scale.decimals)).grouping(.never)
                )
            ))
        }

        // Outer border of the covered area: the iso-line of the coverage (alpha) field.
        var alphaGrid = grid
        alphaGrid.values = grid.alpha
        let border = EnvironmentContours.build(alphaGrid, levels: [borderLevel])

        let png = EnvironmentRaster.pngData(image)?.base64EncodedString() ?? ""
        return EnvironmentSurface(
            image: image,
            pngDataURI: "data:image/png;base64,\(png)",
            contours: contours,
            border: border,
            labels: labels,
            legend: EnvironmentLegend(
                title: metric.displayName,
                unit: metric.displayUnit(radiationInSievert: sievert),
                bands: EnvironmentMetricInfo.bands(for: scale)
            ),
            sensorCount: sensors.count
        )
    }
}
