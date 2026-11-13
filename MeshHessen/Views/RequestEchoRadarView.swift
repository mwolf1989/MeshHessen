import Charts
import SwiftUI

// MARK: - Model

/// One requester on the Funk-Echo radar, aggregated from the (filtered) journal rows.
struct RequestEchoRadarStation: Identifiable, Equatable, Sendable {
    let nodeId: UInt32
    let total: Int
    /// Request count per `RequestEchoType` raw value.
    let perType: [String: Int]

    var id: UInt32 { nodeId }
}

/// Pure radar geometry, ported from the Windows client's `RequestEchoWindow.RenderRadar`.
enum RequestEchoRadarGeometry {
    static let maxStations = 24
    static let sweepDegrees = 42.0
    static let sweepPeriod: TimeInterval = 5
    /// One leg of the live ping (station → us, then us → station).
    static let pingLeg: TimeInterval = 1
    static let pingFlash: TimeInterval = 0.45
    static var pingDuration: TimeInterval { 2 * pingLeg + pingFlash }

    /// Busiest stations first (ties by node id), at most `maxStations`.
    static func stations(from records: [RequestEchoRecord]) -> [RequestEchoRadarStation] {
        var totals: [UInt32: Int] = [:]
        var perType: [UInt32: [String: Int]] = [:]
        for record in records {
            totals[record.nodeId, default: 0] += record.count
            perType[record.nodeId, default: [:]][record.typeRaw, default: 0] += record.count
        }
        return totals
            .map { RequestEchoRadarStation(nodeId: $0.key, total: $0.value, perType: perType[$0.key] ?? [:]) }
            .sorted { $0.total > $1.total || ($0.total == $1.total && $0.nodeId < $1.nodeId) }
            .prefix(maxStations)
            .map { $0 }
    }

    /// Activity on a log scale: 0 … 1, 1 = busiest station.
    static func fraction(total: Int, maxTotal: Int) -> Double {
        let denominator = log(Double(max(maxTotal, 0)) + 1)
        guard denominator > 1e-9 else { return 0 }
        return min(max(log(Double(max(total, 0)) + 1) / denominator, 0), 1)
    }

    /// Stable angle (radians) derived from the node id. Same 32-bit wrapping multiply as the
    /// Windows client, so stations sit at the same spot on both clients.
    static func angle(nodeId: UInt32) -> Double {
        let hashed = nodeId &* 2_654_435_761
        return Double(hashed % 3_600) / 3_600 * 2 * .pi
    }

    /// Busier stations sit closer to the centre.
    static func radius(fraction: Double, maxRadius: Double) -> Double {
        maxRadius * (0.92 - 0.55 * fraction)
    }

    static func position(nodeId: UInt32, fraction: Double, center: CGPoint, maxRadius: Double) -> CGPoint {
        let radius = radius(fraction: fraction, maxRadius: maxRadius)
        let angle = angle(nodeId: nodeId)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    static func dotRadius(fraction: Double) -> Double { 5 + 6 * fraction }
    static func glowRadius(fraction: Double) -> Double { 10 + 8 * fraction }

    /// Scope radius for a canvas size; nil when the canvas is too small to draw.
    static func maxRadius(for size: CGSize) -> Double? {
        guard size.width >= 80, size.height >= 80 else { return nil }
        return min(size.width, size.height) / 2 - 34
    }
}

// MARK: - Radar

/// Retro sonar scope: our node in the centre, requesters around it. More requests = closer,
/// bigger and brighter; the angle derives from the node id so stations keep their place.
struct RequestEchoRadarView: View {
    let records: [RequestEchoRecord]
    let labels: RequestEchoNodeLabels
    let rangeDays: Int
    let reloadToken: Int
    let liveEvent: RequestEchoEvent?
    let actions: RequestEchoRowActions

    @State private var selected: UInt32?
    @State private var hovered: UInt32?
    @State private var hoverLocation: CGPoint = .zero
    @State private var pings: [RadarPing] = []

    private var stations: [RequestEchoRadarStation] {
        RequestEchoRadarGeometry.stations(from: records)
    }

    var body: some View {
        let stations = stations
        VStack(spacing: 0) {
            GeometryReader { proxy in
                scope(stations: stations, size: proxy.size)
            }
            .frame(minHeight: 240)

            if let selected, let station = stations.first(where: { $0.nodeId == selected }) {
                Divider()
                RequestEchoStationDrillDown(
                    station: station,
                    records: records.filter { $0.nodeId == selected },
                    labels: labels,
                    rangeDays: rangeDays,
                    reloadToken: reloadToken,
                    actions: actions
                )
            }
        }
        .onChange(of: liveEvent) { _, event in
            guard let event, stations.contains(where: { $0.nodeId == event.fromId }) else { return }
            let now = Date()
            pings.removeAll { now.timeIntervalSince($0.start) > RequestEchoRadarGeometry.pingDuration }
            pings.append(RadarPing(nodeId: event.fromId, start: now))
        }
    }

    // MARK: - Scope

    private func scope(stations: [RequestEchoRadarStation], size: CGSize) -> some View {
        let layout = RadarLayout(stations: stations, size: size)
        return TimelineView(.animation) { timeline in
            Canvas { context, _ in
                RadarRenderer(
                    layout: layout,
                    labels: labels,
                    selected: selected,
                    pings: pings,
                    now: timeline.date
                ).draw(in: &context)
            }
        }
        .background(RadarPalette.background)
        .overlay(alignment: .topLeading) {
            if stations.isEmpty {
                Text(
                    "No requests recorded yet — as soon as another station wants something from your node, it shows up here."
                )
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RadarPalette.mid)
                .padding(20)
            } else if let hovered, let station = stations.first(where: { $0.nodeId == hovered }) {
                tooltip(for: station)
                    .offset(x: min(hoverLocation.x + 14, max(0, size.width - 220)), y: hoverLocation.y + 14)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                hovered = layout.station(at: location)?.nodeId
            case .ended:
                hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            selected = layout.station(at: value.location)?.nodeId
        })
        .contextMenu {
            if let hovered {
                RequestEchoNodeMenu(
                    nodeId: hovered,
                    routeRecord: latestRouteRecord(for: hovered),
                    actions: actions
                )
            }
        }
    }

    private func tooltip(for station: RequestEchoRadarStation) -> some View {
        let parts = station.perType
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\(RequestEchoType(rawValue: $0.key)?.emoji ?? "❔") \($0.value)" }
            .joined(separator: "  ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(labels.fullName(station.nodeId))
                .fontWeight(.semibold)
            Text("\(station.total) requests")
            Text(verbatim: parts)
        }
        .font(.caption)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    private func latestRouteRecord(for nodeId: UInt32) -> RequestEchoRecord? {
        records.first { $0.nodeId == nodeId && $0.type == .traceroute && !$0.routeNodeIds.isEmpty }
    }
}

// MARK: - Layout

private struct RadarPing: Equatable {
    let nodeId: UInt32
    let start: Date
}

private struct RadarLayout {
    struct PlacedStation {
        let station: RequestEchoRadarStation
        let fraction: Double
        let point: CGPoint
    }

    let center: CGPoint
    let maxRadius: Double?
    let placed: [PlacedStation]

    init(stations: [RequestEchoRadarStation], size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        maxRadius = RequestEchoRadarGeometry.maxRadius(for: size)
        guard let maxRadius else {
            placed = []
            return
        }
        let maxTotal = stations.first?.total ?? 0
        let center = center
        placed = stations.map { station in
            let fraction = RequestEchoRadarGeometry.fraction(total: station.total, maxTotal: maxTotal)
            let point = RequestEchoRadarGeometry.position(
                nodeId: station.nodeId,
                fraction: fraction,
                center: center,
                maxRadius: maxRadius
            )
            return PlacedStation(station: station, fraction: fraction, point: point)
        }
    }

    /// The station whose dot (plus a small margin) contains `location`; closest wins.
    func station(at location: CGPoint) -> RequestEchoRadarStation? {
        placed
            .map { (placed: $0, distance: hypot($0.point.x - location.x, $0.point.y - location.y)) }
            .filter { $0.distance <= RequestEchoRadarGeometry.dotRadius(fraction: $0.placed.fraction) + 4 }
            .min { $0.distance < $1.distance }?
            .placed.station
    }
}

// MARK: - Rendering

private enum RadarPalette {
    static let bright = Color(red: 0x53 / 255, green: 0xFF / 255, blue: 0xB0 / 255)
    static let mid = Color(red: 0x20 / 255, green: 0xC9 / 255, blue: 0x97 / 255)
    static let dim = Color(red: 0x17 / 255, green: 0x6B / 255, blue: 0x4E / 255)
    static let grid = Color(red: 0x14 / 255, green: 0x52 / 255, blue: 0x3C / 255)
    static let background = Color(red: 0x01 / 255, green: 0x05 / 255, blue: 0x03 / 255)
    static let scopeInner = Color(red: 0x07 / 255, green: 0x1E / 255, blue: 0x13 / 255)
    static let scopeOuter = Color(red: 0x01 / 255, green: 0x07 / 255, blue: 0x04 / 255)

    /// Dim → bright phosphor.
    static func phosphor(_ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        func lerp(_ a: Double, _ b: Double) -> Double { (a + (b - a) * t) / 255 }
        return Color(red: lerp(0x17, 0x53), green: lerp(0x6B, 0xFF), blue: lerp(0x4E, 0xB0))
    }
}

private struct RadarRenderer {
    let layout: RadarLayout
    let labels: RequestEchoNodeLabels
    let selected: UInt32?
    let pings: [RadarPing]
    let now: Date

    func draw(in context: inout GraphicsContext) {
        guard let maxRadius = layout.maxRadius else { return }
        let center = layout.center
        drawScope(in: &context, center: center, maxRadius: maxRadius)
        drawSweep(in: &context, center: center, maxRadius: maxRadius)
        for placed in layout.placed {
            drawStation(placed, in: &context, center: center)
        }
        drawOwnNode(in: &context, center: center)
        for ping in pings {
            drawPing(ping, in: &context, center: center, maxRadius: maxRadius)
        }
    }

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawScope(in context: inout GraphicsContext, center: CGPoint, maxRadius: Double) {
        let disc = circle(center, maxRadius + 12)
        context.fill(disc, with: .radialGradient(
            Gradient(colors: [RadarPalette.scopeInner, RadarPalette.scopeOuter]),
            center: center,
            startRadius: 0,
            endRadius: maxRadius + 12
        ))
        context.stroke(disc, with: .color(RadarPalette.dim), lineWidth: 1.5)

        for ring in [0.33, 0.66, 1.0] {
            context.stroke(circle(center, maxRadius * ring), with: .color(RadarPalette.grid.opacity(150 / 255)), lineWidth: 1)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - maxRadius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + maxRadius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - maxRadius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + maxRadius))
        context.stroke(cross, with: .color(RadarPalette.grid.opacity(90 / 255)), lineWidth: 1)
    }

    /// Gradient wedge rotating once per `sweepPeriod`; the leading edge is brightest.
    private func drawSweep(in context: inout GraphicsContext, center: CGPoint, maxRadius: Double) {
        let period = RequestEchoRadarGeometry.sweepPeriod
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let leading = phase * 360
        let slices = 21
        let sliceDegrees = RequestEchoRadarGeometry.sweepDegrees / Double(slices)
        for index in 0..<slices {
            let end = leading - Double(index) * sliceDegrees
            let start = end - sliceDegrees
            // Slices are ~2° wide, so a triangle is indistinguishable from an arc segment.
            func rim(_ degrees: Double) -> CGPoint {
                let radians = degrees * .pi / 180
                return CGPoint(x: center.x + maxRadius * cos(radians), y: center.y + maxRadius * sin(radians))
            }
            var wedge = Path()
            wedge.move(to: center)
            wedge.addLine(to: rim(start))
            wedge.addLine(to: rim(end + 0.3))
            wedge.closeSubpath()
            let opacity = 0.43 * (1 - Double(index) / Double(slices))
            context.fill(wedge, with: .color(RadarPalette.mid.opacity(opacity)))
        }
    }

    private func drawStation(_ placed: RadarLayout.PlacedStation, in context: inout GraphicsContext, center: CGPoint) {
        let fraction = placed.fraction
        let point = placed.point
        let color = RadarPalette.phosphor(0.35 + 0.65 * fraction)

        var line = Path()
        line.move(to: center)
        line.addLine(to: point)
        context.stroke(
            line,
            with: .color(RadarPalette.dim.opacity(110 / 255)),
            style: StrokeStyle(lineWidth: 1 + 1.5 * fraction, dash: [2, 3])
        )

        let dotRadius = RequestEchoRadarGeometry.dotRadius(fraction: fraction)
        let dot = circle(point, dotRadius)
        context.drawLayer { layer in
            layer.addFilter(.shadow(
                color: color.opacity(0.9),
                radius: RequestEchoRadarGeometry.glowRadius(fraction: fraction) / 2
            ))
            layer.fill(dot, with: .color(color))
        }
        if placed.station.nodeId == selected {
            context.stroke(dot, with: .color(.white), lineWidth: 2)
        }

        let label = Text(verbatim: labels.shortLabel(placed.station.nodeId))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(RadarPalette.mid.opacity(220 / 255))
        context.draw(label, at: CGPoint(x: point.x, y: point.y + dotRadius + 2), anchor: .top)
    }

    /// Our node: a small antenna mast with glow and a "Me" label.
    private func drawOwnNode(in context: inout GraphicsContext, center: CGPoint) {
        var mast = Path()
        mast.move(to: CGPoint(x: center.x, y: center.y - 7))
        mast.addLine(to: CGPoint(x: center.x - 4.8, y: center.y + 7))
        mast.addLine(to: CGPoint(x: center.x + 4.8, y: center.y + 7))
        mast.closeSubpath()
        mast.move(to: CGPoint(x: center.x - 3, y: center.y + 2.8))
        mast.addLine(to: CGPoint(x: center.x + 3, y: center.y + 2.8))
        mast.move(to: CGPoint(x: center.x - 2, y: center.y - 1.4))
        mast.addLine(to: CGPoint(x: center.x + 2, y: center.y - 1.4))
        mast.move(to: CGPoint(x: center.x, y: center.y - 7))
        mast.addLine(to: CGPoint(x: center.x, y: center.y - 10))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: RadarPalette.bright.opacity(0.9), radius: 6))
            layer.stroke(
                mast,
                with: .color(RadarPalette.bright),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        let label = Text("Me")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(RadarPalette.mid)
        context.draw(label, at: CGPoint(x: center.x, y: center.y + 14), anchor: .top)
    }

    /// Sonar ping: a ring grows from the sender until it reaches us, is "reflected" back
    /// out to the sender, which then flashes.
    private func drawPing(_ ping: RadarPing, in context: inout GraphicsContext, center: CGPoint, maxRadius: Double) {
        let elapsed = now.timeIntervalSince(ping.start)
        guard elapsed >= 0, elapsed < RequestEchoRadarGeometry.pingDuration else { return }
        let point = layout.placed.first { $0.station.nodeId == ping.nodeId }?.point
            ?? RequestEchoRadarGeometry.position(
                nodeId: ping.nodeId, fraction: 0.2, center: center, maxRadius: maxRadius
            )
        let distance = max(hypot(point.x - center.x, point.y - center.y), 12)
        let leg = RequestEchoRadarGeometry.pingLeg

        if elapsed < 2 * leg {
            let origin = elapsed < leg ? point : center
            let progress = (elapsed < leg ? elapsed : elapsed - leg) / leg
            let radius = distance * (0.04 + 0.96 * progress)
            let opacity = 0.9 - 0.65 * progress
            context.stroke(circle(origin, radius), with: .color(RadarPalette.bright.opacity(opacity)), lineWidth: 2)
        } else {
            let progress = (elapsed - 2 * leg) / RequestEchoRadarGeometry.pingFlash
            let radius = 13 * (0.3 + 1.1 * progress)
            context.fill(
                circle(point, radius),
                with: .color(RadarPalette.bright.opacity(160 / 255 * (1 - progress)))
            )
        }
    }
}

// MARK: - Drill-down

/// Hourly requests and per-type breakdown for the station picked on the radar.
private struct RequestEchoStationDrillDown: View {
    let station: RequestEchoRadarStation
    let records: [RequestEchoRecord]
    let labels: RequestEchoNodeLabels
    let rangeDays: Int
    let reloadToken: Int
    let actions: RequestEchoRowActions

    @State private var points: [TelemetrySeriesPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(labels.fullName(station.nodeId)) · \(station.total) requests")
                    .font(.callout.weight(.semibold))
                Spacer()
                Menu {
                    RequestEchoNodeMenu(nodeId: station.nodeId, routeRecord: routeRecord, actions: actions)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions")
            }

            Text(verbatim: breakdown)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !points.isEmpty {
                Chart(points) { point in
                    BarMark(
                        x: .value("Hour", point.timestamp, unit: .hour),
                        y: .value("Requests", point.value)
                    )
                    .foregroundStyle(RadarPalette.mid.opacity(0.8))
                }
                .chartYAxisLabel("requests/h")
                .frame(height: 130)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu {
            RequestEchoNodeMenu(nodeId: station.nodeId, routeRecord: routeRecord, actions: actions)
        }
        .task(id: "\(station.nodeId)-\(rangeDays)-\(reloadToken)") { await load() }
    }

    private var routeRecord: RequestEchoRecord? {
        records.first { $0.type == .traceroute && !$0.routeNodeIds.isEmpty }
    }

    private var breakdown: String {
        var counts: [String: Int] = [:]
        var details: [String: Int] = [:]
        for record in records {
            counts[record.typeRaw, default: 0] += record.count
            if record.type == .telemetry {
                details[record.detail ?? "", default: 0] += record.count
            }
        }
        return counts
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { raw, count in
                let type = RequestEchoType(rawValue: raw)
                let value: String
                if type == .telemetry, !details.isEmpty {
                    value = details
                        .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                        .map { "\(RequestEchoTelemetryDetail.label(for: $0.key)) \($0.value)" }
                        .joined(separator: ", ")
                } else {
                    value = "\(count)"
                }
                return "\(type?.emoji ?? "❔") \(type?.displayName ?? raw): \(value)"
            }
            .joined(separator: "   ·   ")
    }

    private func load() async {
        let nodeId = station.nodeId
        let days = rangeDays
        let series = await Task.detached(priority: .utility) {
            TelemetryDatabaseService.shared.getTimeSeries(nodeIds: [nodeId], metric: .funkEcho, days: days)
        }.value
        guard !Task.isCancelled else { return }
        points = series.sorted { $0.timestamp < $1.timestamp }
    }
}
