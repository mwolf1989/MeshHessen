import Charts
import SwiftUI

/// What to open a link elevation profile for: two named ends with optional positions.
struct LinkProfileRequest: Identifiable, Equatable {
    let id = UUID()
    let startName: String
    let start: LinkProfilePoint?
    let endName: String
    let end: LinkProfilePoint?

    /// Both ends have a position (the menu entry is disabled otherwise).
    var isAvailable: Bool { start != nil && end != nil }

    init(startName: String, start: LinkProfilePoint?, endName: String, end: LinkProfilePoint?) {
        self.startName = startName
        self.start = start
        self.endName = endName
        self.end = end
    }

    init(
        startName: String,
        startLatitude: Double?,
        startLongitude: Double?,
        endName: String,
        endLatitude: Double?,
        endLongitude: Double?
    ) {
        self.init(
            startName: startName,
            start: Self.point(startLatitude, startLongitude),
            endName: endName,
            end: Self.point(endLatitude, endLongitude)
        )
    }

    static func point(_ latitude: Double?, _ longitude: Double?) -> LinkProfilePoint? {
        guard let latitude, let longitude else { return nil }
        return LinkProfilePoint(latitude: latitude, longitude: longitude)
    }

    /// Current position of a node; the own node uses the effective own position
    /// (manual position first), like the map does.
    @MainActor
    static func position(of nodeId: UInt32, in appState: AppState) -> LinkProfilePoint? {
        if nodeId == appState.myNodeInfo?.nodeId, let own = appState.effectiveOwnCoordinate() {
            return LinkProfilePoint(latitude: own.latitude, longitude: own.longitude)
        }
        let node = appState.node(forId: nodeId)
        return point(node?.latitude, node?.longitude)
    }
}

/// Context-menu entry that opens a link profile; disabled with a tooltip when a position is missing.
struct LinkProfileMenuButton: View {
    let request: LinkProfileRequest
    let onOpen: (LinkProfileRequest) -> Void

    var body: some View {
        Button("Link Elevation Profile", systemImage: "mountain.2") {
            onOpen(request)
        }
        .disabled(!request.isAvailable)
        .help(request.isAvailable
            ? Text("Terrain, line of sight and 60 % Fresnel zone between both nodes")
            : Text("No position known for one of the two nodes."))
    }
}

/// Elevation profile of one RF link: terrain (plus 4/3-earth bulge), line of sight and
/// the 60 % first Fresnel zone at 868 MHz, with clearance, loss estimate and verdict.
struct LinkProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: LinkProfileRequest

    @State private var startHeight = LinkProfile.defaultAntennaHeight
    @State private var endHeight = LinkProfile.defaultAntennaHeight
    @State private var grid: TerrainGrid?
    @State private var isLoading = true

    private var result: LinkProfileResult? {
        guard let start = request.start, let end = request.end else { return nil }
        return LinkProfile.compute(
            from: start,
            to: end,
            antennaHeights: (startHeight, endHeight),
            grid: grid
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            antennaControls
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .task { await loadTerrain() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elevation Profile")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(verbatim: headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var headerSubtitle: String {
        let distance = result.map { Self.kilometres($0.distance) } ?? "–"
        return "\(request.startName)  →  \(request.endName)  ·  \(distance)"
    }

    @ViewBuilder
    private var content: some View {
        if !request.isAvailable {
            ContentUnavailableView(
                "No Position",
                systemImage: "location.slash",
                description: Text("No position known for one of the two nodes.")
            )
        } else if isLoading {
            ProgressView("Loading elevation data…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result, result.verdict != .unknown {
            VStack(alignment: .leading, spacing: 10) {
                LinkProfileSummary(result: result)
                LinkProfileChart(result: result)
            }
        } else {
            ContentUnavailableView(
                "No Elevation Data",
                systemImage: "mountain.2",
                description: Text("No elevation data available for this path (offline without cache, or outside the elevation model's coverage, north of 52° N).")
            )
        }
    }

    private var antennaControls: some View {
        HStack(spacing: 20) {
            AntennaHeightField(title: "Antenna height \(request.startName)", value: $startHeight)
            AntennaHeightField(title: "Antenna height \(request.endName)", value: $endHeight)
            Spacer()
        }
        .disabled(!request.isAvailable)
    }

    // MARK: - Loading

    private func loadTerrain() async {
        guard let start = request.start, let end = request.end else {
            isLoading = false
            return
        }
        let terrain = TerrainService.shared
        await terrain.setOfflineOnly(SettingsService.shared.mapMode == .offline)
        let loaded = await terrain.grid(covering: TerrainBounds(
            latitude1: start.latitude,
            longitude1: start.longitude,
            latitude2: end.latitude,
            longitude2: end.longitude
        ))
        if loaded == nil {
            AppLogger.shared.log("[LinkProfile] no terrain grid for \(request.startName) → \(request.endName)")
        }
        grid = loaded
        isLoading = false
    }

    static func kilometres(_ metres: Double) -> String {
        (metres / 1_000).formatted(.number.precision(.fractionLength(1))) + " km"
    }

    static func metres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " m"
    }
}

// MARK: - Summary

private struct LinkProfileSummary: View {
    let result: LinkProfileResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Label(verdictTitle, systemImage: verdictSymbol)
                .font(.headline)
                .foregroundStyle(verdictColor)
            if let margin = result.worstMargin, let at = result.worstMarginDistance {
                Text("Smallest clearance: \(LinkProfileSheet.metres(margin)) at \(LinkProfileSheet.kilometres(at))")
                    .help("Distance between the lower edge of the 60 % Fresnel zone and the terrain (including earth bulge); negative = terrain intrudes.")
            }
            Text("Estimated extra loss: ≈ \(result.knifeEdgeLoss.formatted(.number.precision(.fractionLength(0)))) dB")
                .help("Knife-edge diffraction loss at the worst obstacle (ITU-R P.526 approximation).")
        }
        .font(.callout)
    }

    private var verdictTitle: String {
        switch result.verdict {
        case .clear: String(localized: "Line of sight clear")
        case .marginal: String(localized: "Fresnel zone partly obstructed")
        case .obstructed: String(localized: "Terrain in the way")
        case .unknown: String(localized: "No elevation data")
        }
    }

    private var verdictSymbol: String {
        switch result.verdict {
        case .clear: "checkmark.circle.fill"
        case .marginal: "exclamationmark.triangle.fill"
        case .obstructed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var verdictColor: Color {
        switch result.verdict {
        case .clear: .green
        case .marginal: .orange
        case .obstructed: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - Chart

private struct LinkProfileChart: View {
    let result: LinkProfileResult

    private var terrainLabel: String { String(localized: "Terrain (4/3 earth)") }
    private var lineOfSightLabel: String { String(localized: "Line of sight") }
    private var fresnelLabel: String { String(localized: "60 % Fresnel zone") }

    /// Bottom of the terrain area: a little below the lowest point of the plot.
    private var baseline: Double {
        let lowest = result.samples.map { min($0.ground, $0.fresnelLowerEdge) }.min() ?? 0
        return (lowest - 10).rounded(.down)
    }

    var body: some View {
        let baseline = baseline
        Chart {
            ForEach(Array(result.samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(
                    x: .value("Distance", sample.distance / 1_000),
                    yStart: .value("Height", sample.fresnelLowerEdge),
                    yEnd: .value("Height", sample.lineOfSight + 0.6 * sample.fresnelRadius),
                    series: .value("Series", fresnelLabel)
                )
                .foregroundStyle(by: .value("Series", fresnelLabel))
                .opacity(0.25)
            }
            ForEach(Array(result.samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(
                    x: .value("Distance", sample.distance / 1_000),
                    yStart: .value("Height", baseline),
                    yEnd: .value("Height", sample.ground),
                    series: .value("Series", terrainLabel)
                )
                .foregroundStyle(by: .value("Series", terrainLabel))
                .opacity(0.55)
            }
            ForEach(Array(result.samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Distance", sample.distance / 1_000),
                    y: .value("Height", sample.lineOfSight),
                    series: .value("Series", lineOfSightLabel)
                )
                .foregroundStyle(by: .value("Series", lineOfSightLabel))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let at = result.worstMarginDistance {
                RuleMark(x: .value("Distance", at / 1_000))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale([
            terrainLabel: Color(red: 0.30, green: 0.49, blue: 0.24),
            lineOfSightLabel: Color.primary,
            fresnelLabel: Color.orange,
        ])
        .chartXScale(domain: 0...max(result.distance / 1_000, 0.01))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .chartLegend(position: .top, alignment: .trailing)
        .accessibilityLabel(Text("Elevation profile chart"))
    }
}

// MARK: - Antenna height

private struct AntennaHeightField: View {
    let title: LocalizedStringKey
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField(
                title,
                value: $value,
                format: .number.precision(.fractionLength(0...1))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            Stepper(title, value: $value, in: 0...300, step: 0.5)
                .labelsHidden()
            Text(verbatim: "m")
                .foregroundStyle(.secondary)
        }
        .onChange(of: value) { _, newValue in
            let clamped = min(max(newValue, 0), 300)
            if clamped != newValue { value = clamped }
        }
    }
}
