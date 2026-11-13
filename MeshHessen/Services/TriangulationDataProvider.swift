import Foundation
import Observation
import os

// MARK: - Inputs

/// One `rf_links` row with a known SNR (`observer` heard `neighbor`).
struct RfLinkSnrRow: Equatable, Sendable {
    let observer: UInt32
    let neighbor: UInt32
    let snr: Double
}

/// Known position of a node; `errorKm` is its own uncertainty (precision truncation).
struct TriangulationPosition: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var errorKm: Double = 0
}

/// Expert hooks (Windows' link-budget dialog and map picker, not exposed in the UI yet):
/// per-node link budget, antenna height and an exactly known position.
struct TriangulationNodeOverride: Equatable, Sendable {
    var txDbm = TriangulationService.referenceTxDbm
    var antennaDbi = TriangulationService.referenceAntennaDbi
    var antennaHeightM = TriangulationService.defaultAntennaHeightM
    /// The node's position is exact: its precision dead zone collapses to a point.
    var positionIsExact = false
    /// Hand-picked coordinates replacing the reported position (implies exact).
    var exactPosition: TriangulationPosition?
}

/// Signal evidence between the target and one RF partner (robust 30-day values).
struct TriangulationLinkEvidence: Equatable, Sendable {
    let partnerId: UInt32
    /// The target heard the partner at this SNR.
    var snrIn: Double?
    /// The partner heard the target at this SNR.
    var snrOut: Double?
    /// RSSI the own node measured from the target (only when the partner is the own node).
    var ownRssi: Double?

    var hasSignal: Bool { ownRssi != nil || snrIn != nil || snrOut != nil }
}

/// Everything the anchor builder needs, collected from the database and `AppState`.
struct TriangulationInput: Sendable {
    var targetId: UInt32
    var myNodeId: UInt32
    var positions: [UInt32: TriangulationPosition]
    var links: [TriangulationLinkEvidence]
    var noiseFloors: [UInt32: Double]
    var names: [UInt32: String]
    var overrides: [UInt32: TriangulationNodeOverride] = [:]
}

// MARK: - Anchors

/// Kind of evidence behind a distance circle (drives its uncertainty).
enum TriangulationEvidence: String, Equatable, Sendable {
    /// RSSI measured by the own node — the sharpest evidence.
    case rssi
    /// SNR in both directions.
    case snrBothWays
    /// SNR in one direction only.
    case snrOneWay
    /// The target's own reported position (not an RF link).
    case reportedPosition
}

/// One anchor of a triangulation: a positioned node with a distance circle.
struct TriangulationAnchor: Identifiable, Equatable, Sendable {
    /// Partner node, nil for the target's reported-position prior.
    let nodeId: UInt32?
    let name: String
    let latitude: Double
    let longitude: Double
    let distanceKm: Double
    let positionErrorKm: Double
    let sigmaKm: Double
    let weightScale: Double
    let evidence: TriangulationEvidence
    /// The SNR → RSSI conversion fell back to the default noise floor.
    let noiseFloorDefaulted: Bool
    let antennaHeightM: Double

    var id: String { nodeId.map { String(format: "!%08x", $0) } ?? "prior" }
    var isPrior: Bool { evidence == .reportedPosition }

    var solverAnchor: TriangulationService.Anchor {
        .init(
            lat: latitude,
            lon: longitude,
            distKm: distanceKm,
            posErrKm: positionErrorKm,
            weightScale: weightScale,
            sigmaKm: sigmaKm
        )
    }
}

// MARK: - Terrain seam

/// Elevation in metres above sea level at (latitude, longitude), nil without data.
typealias TriangulationElevationSampler = @Sendable (Double, Double) -> Double?

/// Source of terrain heights for the solver's diffraction term. `TerrainService`
/// conforms (see `TerrainService.swift`); `NoTriangulationTerrain` keeps the flat model.
protocol TriangulationTerrainSource: Sendable {
    func elevationSampler(
        minLatitude: Double,
        minLongitude: Double,
        maxLatitude: Double,
        maxLongitude: Double
    ) async -> TriangulationElevationSampler?
}

/// No terrain data: the solver uses the flat model (logged once per launch).
struct NoTriangulationTerrain: TriangulationTerrainSource {
    private static let logged = OSAllocatedUnfairLock(initialState: false)

    func elevationSampler(
        minLatitude: Double,
        minLongitude: Double,
        maxLatitude: Double,
        maxLongitude: Double
    ) async -> TriangulationElevationSampler? {
        let first = Self.logged.withLock { logged in
            defer { logged = true }
            return !logged
        }
        if first {
            AppLogger.shared.log("[Triangulation] No terrain service available — using the flat model")
        }
        return nil
    }
}

// MARK: - Result

struct TriangulationOutcome: Equatable, Sendable {
    let targetId: UInt32
    let anchors: [TriangulationAnchor]
    let calibration: TriangulationService.Calibration
    let estimate: TriangulationService.EstimateResult
    let bandFactor: Double
    let usedTerrain: Bool

    /// RF anchors (without the reported-position prior).
    var rfAnchorCount: Int { anchors.filter { !$0.isPrior }.count }
}

// MARK: - Provider

/// Turns collected link evidence into triangulation anchors (Windows
/// `MainWindow.TriangulateNodeOnMap` / `ComputePathLossCalibration`). Estimates are
/// display-only: nothing here writes positions anywhere.
enum TriangulationDataProvider {
    /// Window of the signal histories behind the trimmed medians.
    static let historyDays = 30
    /// Noise floor assumed when a node never reported LocalStats.
    static let defaultNoiseFloorDbm = -105.0
    static let minimumAnchors = 2
    /// Positions less precise than this make unusable calibration ground truth.
    static let maxCalibrationPositionErrorKm = 0.5

    /// Recommend the fitted model only when it explains the data and stayed inside the
    /// physical bounds.
    static func recommendsFitted(_ calibration: TriangulationService.Calibration) -> Bool {
        calibration.isFitted && calibration.r2 >= 0.2 && !calibration.clamped
    }

    // MARK: Pure steps

    /// (true distance, pseudo-RSSI) pairs from links whose both ends have precise
    /// positions; SNR → RSSI with the observer's noise floor.
    static func calibrationSamples(
        rows: [RfLinkSnrRow],
        positions: [UInt32: TriangulationPosition],
        noiseFloors: [UInt32: Double]
    ) -> [(distKm: Double, rssi: Double)] {
        rows.compactMap { row in
            guard let a = positions[row.observer], let b = positions[row.neighbor],
                  a.errorKm <= maxCalibrationPositionErrorKm, b.errorKm <= maxCalibrationPositionErrorKm else {
                return nil
            }
            let kx = 111.320 * cos(((a.latitude + b.latitude) / 2) * .pi / 180)
            let dx = (b.longitude - a.longitude) * kx, dy = (b.latitude - a.latitude) * 110.574
            return (sqrt(dx * dx + dy * dy), row.snr + (noiseFloors[row.observer] ?? defaultNoiseFloorDbm))
        }
    }

    /// Nodes that have at least two positioned RF partners with an SNR — the targets the
    /// picker offers (a quick pre-filter; the full anchor check runs on selection).
    static func candidateTargets(rows: [RfLinkSnrRow], positions: [UInt32: TriangulationPosition]) -> Set<UInt32> {
        var partners: [UInt32: Set<UInt32>] = [:]
        for row in rows {
            if positions[row.neighbor] != nil { partners[row.observer, default: []].insert(row.neighbor) }
            if positions[row.observer] != nil { partners[row.neighbor, default: []].insert(row.observer) }
        }
        return Set(partners.compactMap { $0.value.count >= minimumAnchors ? $0.key : nil })
    }

    /// Builds the distance circles for the target: positioned partners with signal
    /// evidence, then the target's own reported position as a prior.
    static func anchors(
        for input: TriangulationInput,
        calibration: TriangulationService.Calibration,
        reportedPositionName: String
    ) -> [TriangulationAnchor] {
        let bandFactor = TriangulationService.distanceFactor(calibration)
        let target = input.overrides[input.targetId] ?? TriangulationNodeOverride()
        let targetNoiseFloor = input.noiseFloors[input.targetId]
        var anchors: [TriangulationAnchor] = []

        for link in input.links where link.partnerId != input.targetId && link.hasSignal {
            guard let reported = input.positions[link.partnerId] else { continue }
            let partner = input.overrides[link.partnerId] ?? TriangulationNodeOverride()

            var candidates: [Double] = []
            var sigmaMultiplier: Double
            var evidence: TriangulationEvidence
            var noiseFloorDefaulted = false
            if let rssi = link.ownRssi {
                // The target transmitted, the partner (own node) received.
                candidates.append(TriangulationService.adjustedRssi(
                    rssi, txDbm: target.txDbm, txAntennaDbi: target.antennaDbi, rxAntennaDbi: partner.antennaDbi
                ))
                sigmaMultiplier = 1.0
                evidence = .rssi
            } else {
                // SNR-derived pseudo-RSSI is soft evidence: wider circles.
                let partnerNoiseFloor = input.noiseFloors[link.partnerId]
                if let snrOut = link.snrOut {
                    candidates.append(TriangulationService.adjustedRssi(
                        snrOut + (partnerNoiseFloor ?? defaultNoiseFloorDbm),
                        txDbm: target.txDbm, txAntennaDbi: target.antennaDbi, rxAntennaDbi: partner.antennaDbi
                    ))
                    noiseFloorDefaulted = noiseFloorDefaulted || partnerNoiseFloor == nil
                }
                if let snrIn = link.snrIn {
                    candidates.append(TriangulationService.adjustedRssi(
                        snrIn + (targetNoiseFloor ?? defaultNoiseFloorDbm),
                        txDbm: partner.txDbm, txAntennaDbi: partner.antennaDbi, rxAntennaDbi: target.antennaDbi
                    ))
                    noiseFloorDefaulted = noiseFloorDefaulted || targetNoiseFloor == nil
                }
                let bothWays = link.snrOut != nil && link.snrIn != nil
                sigmaMultiplier = bothWays ? 1.3 : 1.7
                evidence = bothWays ? .snrBothWays : .snrOneWay
                if noiseFloorDefaulted { sigmaMultiplier += 0.3 }
            }
            guard !candidates.isEmpty else { continue }

            let position: TriangulationPosition
            if let exact = partner.exactPosition {
                position = TriangulationPosition(latitude: exact.latitude, longitude: exact.longitude, errorKm: 0)
            } else {
                position = TriangulationPosition(
                    latitude: reported.latitude,
                    longitude: reported.longitude,
                    errorKm: partner.positionIsExact ? 0 : reported.errorKm
                )
            }
            let distance = TriangulationService.signalDistanceKm(
                candidates.reduce(0, +) / Double(candidates.count),
                calibration
            )
            anchors.append(TriangulationAnchor(
                nodeId: link.partnerId,
                name: input.names[link.partnerId] ?? String(format: "!%08x", link.partnerId),
                latitude: position.latitude,
                longitude: position.longitude,
                distanceKm: distance,
                positionErrorKm: position.errorKm,
                sigmaKm: (bandFactor - 1) * distance * sigmaMultiplier,
                weightScale: 1,
                evidence: evidence,
                noiseFloorDefaulted: noiseFloorDefaulted,
                antennaHeightM: partner.antennaHeightM
            ))
        }

        // The target's own (possibly truncated) position is hard information: distance 0
        // with the truncation cell as dead zone.
        let reportedTarget = target.exactPosition ?? input.positions[input.targetId]
        if let reportedTarget {
            let exact = target.positionIsExact || target.exactPosition != nil
            anchors.append(TriangulationAnchor(
                nodeId: nil,
                name: reportedPositionName,
                latitude: reportedTarget.latitude,
                longitude: reportedTarget.longitude,
                distanceKm: 0,
                positionErrorKm: exact ? 0.05 : max(reportedTarget.errorKm, 0.2),
                sigmaKm: 0,
                weightScale: 5,
                evidence: .reportedPosition,
                noiseFloorDefaulted: false,
                antennaHeightM: 0
            ))
        }
        return anchors
    }

    /// Runs the solver (with terrain when the source has data). Nil with fewer than two
    /// RF anchors.
    static func solve(
        targetId: UInt32,
        anchors: [TriangulationAnchor],
        calibration: TriangulationService.Calibration,
        targetAntennaHeightM: Double = TriangulationService.defaultAntennaHeightM,
        terrain: any TriangulationTerrainSource = NoTriangulationTerrain()
    ) async -> TriangulationOutcome? {
        guard anchors.filter({ !$0.isPrior }).count >= minimumAnchors else { return nil }
        let solverAnchors = anchors.map(\.solverAnchor)

        var context: TriangulationService.TerrainContext?
        if let bounds = TriangulationService.searchBounds(solverAnchors),
           let sampler = await terrain.elevationSampler(
               minLatitude: bounds.minLat,
               minLongitude: bounds.minLon,
               maxLatitude: bounds.maxLat,
               maxLongitude: bounds.maxLon
           ) {
            context = TriangulationService.TerrainContext(
                elevationAt: { sampler($0, $1) },
                anchorHeightM: anchors.map(\.antennaHeightM),
                targetHeightM: targetAntennaHeightM,
                exponent: calibration.exponent
            )
        }

        guard let estimate = TriangulationService.estimate(solverAnchors, terrain: context) else { return nil }
        return TriangulationOutcome(
            targetId: targetId,
            anchors: anchors,
            calibration: calibration,
            estimate: estimate,
            bandFactor: TriangulationService.distanceFactor(calibration),
            usedTerrain: context != nil
        )
    }

    // MARK: Database

    /// Everything that does not depend on the chosen target, loaded once per sheet.
    struct Context: Sendable {
        let myNodeId: UInt32
        let positions: [UInt32: TriangulationPosition]
        let names: [UInt32: String]
        let noiseFloors: [UInt32: Double]
        /// Self-calibrated model, or `.default` when the data is too thin.
        let fittedCalibration: TriangulationService.Calibration
        /// Offered targets, sorted by name.
        let candidates: [UInt32]
    }

    /// Positions (live first, then the last 30 days of `node_positions`), noise floors,
    /// self-calibration and the candidate targets.
    static func loadContext(
        livePositions: [UInt32: TriangulationPosition],
        names: [UInt32: String],
        myNodeId: UInt32,
        initialTargetId: UInt32,
        database: TelemetryDatabaseService,
        now: Date = Date()
    ) async -> Context {
        var positions = livePositions
        for (nodeId, stored) in await database.latestNodePositions(maxAgeDays: historyDays)
        where positions[nodeId] == nil {
            positions[nodeId] = TriangulationPosition(latitude: stored.latitude, longitude: stored.longitude)
        }
        let noiseFloors = await database.latestNoiseFloors()
        let rows = await database.rfLinkSnrRows(since: now.addingTimeInterval(-Double(historyDays) * 86_400))
        let calibration = TriangulationService.fitCalibration(
            calibrationSamples(rows: rows, positions: positions, noiseFloors: noiseFloors)
        )
        var candidates = candidateTargets(rows: rows, positions: positions)
        candidates.insert(initialTargetId)
        func name(_ id: UInt32) -> String { names[id] ?? String(format: "!%08x", id) }
        return Context(
            myNodeId: myNodeId,
            positions: positions,
            names: names,
            noiseFloors: noiseFloors,
            fittedCalibration: calibration,
            candidates: candidates.sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        )
    }

    /// Loads the target's links, builds the anchors and solves. Nil = too few anchors.
    static func triangulate(
        targetId: UInt32,
        context: Context,
        calibration: TriangulationService.Calibration,
        overrides: [UInt32: TriangulationNodeOverride] = [:],
        database: TelemetryDatabaseService,
        terrain: any TriangulationTerrainSource = NoTriangulationTerrain(),
        now: Date = Date()
    ) async -> TriangulationOutcome? {
        let links = await loadLinks(targetId: targetId, myNodeId: context.myNodeId, database: database, now: now)
        let input = TriangulationInput(
            targetId: targetId,
            myNodeId: context.myNodeId,
            positions: context.positions,
            links: links,
            noiseFloors: context.noiseFloors,
            names: context.names,
            overrides: overrides
        )
        let anchors = anchors(
            for: input,
            calibration: calibration,
            reportedPositionName: String(localized: "reported position")
        )
        let outcome = await solve(
            targetId: targetId,
            anchors: anchors,
            calibration: calibration,
            targetAntennaHeightM: overrides[targetId]?.antennaHeightM ?? TriangulationService.defaultAntennaHeightM,
            terrain: terrain
        )
        if let outcome {
            let estimate = outcome.estimate
            AppLogger.shared.log(String(
                format: "[Triangulation] !%08x: %d anchors → est %.5f,%.5f ±%.1f km%@ (model: %@, terrain: %@)",
                targetId,
                outcome.anchors.count,
                estimate.lat,
                estimate.lon,
                estimate.uncertaintyKm,
                estimate.hasAlternative
                    ? String(format: " ALT %.5f,%.5f", estimate.altLat ?? 0, estimate.altLon ?? 0)
                    : "",
                calibration.isFitted
                    ? String(format: "self-calibrated P1km=%.1f n=%.2f σ=%.1f R²=%.2f from %d links",
                             calibration.p1Km, calibration.exponent, calibration.sigmaDb, calibration.r2,
                             calibration.samples)
                    : "default",
                outcome.usedTerrain ? "DEM" : "flat"
            ))
        }
        return outcome
    }

    /// Robust per-partner signal values of the target from the last 30 days: trimmed
    /// medians of `rf_link_obs` / own `packet_rx` receptions, falling back to the
    /// `rf_links` snapshot (SNR) or the latest direct contact (own RSSI).
    static func loadLinks(
        targetId: UInt32,
        myNodeId: UInt32,
        database: TelemetryDatabaseService,
        now: Date = Date()
    ) async -> [TriangulationLinkEvidence] {
        let cutoff = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let partners = await database.rfNeighbors(of: targetId)
        var links: [TriangulationLinkEvidence] = []
        for partner in partners {
            let snrIn = TriangulationService.trimmedMedian(await database.rfLinkSnrSamples(
                observer: targetId, neighbor: partner.neighborId, myNodeId: myNodeId, since: cutoff
            )) ?? partner.snrIn.map(Double.init)
            let snrOut = TriangulationService.trimmedMedian(await database.rfLinkSnrSamples(
                observer: partner.neighborId, neighbor: targetId, myNodeId: myNodeId, since: cutoff
            )) ?? partner.snrOut.map(Double.init)

            var ownRssi: Double?
            if partner.neighborId == myNodeId, myNodeId != 0 {
                ownRssi = TriangulationService.trimmedMedian(
                    await database.directRssiSamples(nodeId: targetId, since: cutoff)
                ).map { $0.rounded() }
                if ownRssi == nil {
                    ownRssi = database.getDirectNeighborContacts()
                        .first { $0.nodeId == targetId }?
                        .rssi.flatMap { $0 != 0 ? Double($0) : nil }
                }
            }
            links.append(TriangulationLinkEvidence(
                partnerId: partner.neighborId,
                snrIn: snrIn,
                snrOut: snrOut,
                ownRssi: ownRssi
            ))
        }
        return links
    }
}

// MARK: - Map layer

/// A triangulation drawn on the map: dashed distance circles around the anchors, the
/// uncertainty region and a triangle marker at the estimate. Display-only.
struct TriangulationMapLayer: Identifiable, Equatable, Sendable {
    enum RingStyle: Equatable, Sendable {
        /// Model distance around an RF anchor (dashed).
        case distance
        /// Outer band: model spread plus the anchor's position error (dotted).
        case band
    }

    struct Ring: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
        let style: RingStyle
    }

    struct Label: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let text: String
    }

    let targetId: UInt32
    let targetName: String
    let colorHex: String
    let anchors: [TriangulationAnchor]
    let estimate: TriangulationService.EstimateResult
    let bandFactor: Double
    /// Increases with every layer shown; the maps fit the newest one into view.
    let revision: Int

    var id: UInt32 { targetId }

    var rings: [Ring] {
        anchors.flatMap { anchor -> [Ring] in
            var rings: [Ring] = []
            if !anchor.isPrior {
                rings.append(.init(
                    latitude: anchor.latitude, longitude: anchor.longitude,
                    radiusKm: anchor.distanceKm, style: .distance
                ))
            }
            let bandKm = anchor.isPrior
                ? anchor.positionErrorKm
                : anchor.distanceKm * bandFactor + anchor.positionErrorKm
            if bandKm > 0.05 {
                rings.append(.init(latitude: anchor.latitude, longitude: anchor.longitude, radiusKm: bandKm, style: .band))
            }
            return rings
        }
    }

    /// One label per anchor at the top of its distance circle (or the prior's cell).
    var anchorLabels: [Label] {
        anchors.map { anchor in
            let text = anchor.isPrior
                ? "\(anchor.name): ±\(Self.km(anchor.positionErrorKm)) km"
                : "\(anchor.name): \(Self.km(anchor.distanceKm)) km"
                    + (anchor.positionErrorKm >= 0.5 ? " (±\(Self.km(anchor.positionErrorKm)))" : "")
            let radius = anchor.isPrior ? anchor.positionErrorKm : anchor.distanceKm
            return Label(latitude: anchor.latitude + radius / 110.574, longitude: anchor.longitude, text: text)
        }
    }

    var estimateLabel: String {
        "📍 ~\(targetName) (±\(Self.km(estimate.uncertaintyKm)) km)"
    }

    var alternativeLabel: String {
        "📍 \(targetName)? (\(String(localized: "Alternative")))"
    }

    /// Bounding box of all rings and markers.
    var bounds: (minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        var points = rings.flatMap { Self.circle(latitude: $0.latitude, longitude: $0.longitude, radiusKm: $0.radiusKm) }
        points += Self.circle(latitude: estimate.lat, longitude: estimate.lon, radiusKm: estimate.uncertaintyKm)
        if let altLat = estimate.altLat, let altLon = estimate.altLon {
            points.append((altLat, altLon))
        }
        return (
            points.map(\.latitude).min() ?? estimate.lat,
            points.map(\.longitude).min() ?? estimate.lon,
            points.map(\.latitude).max() ?? estimate.lat,
            points.map(\.longitude).max() ?? estimate.lon
        )
    }

    /// Closed circle polygon (`segments + 1` points, first == last) around a centre, in the
    /// solver's local km projection.
    static func circle(
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        segments: Int = 64
    ) -> [(latitude: Double, longitude: Double)] {
        let kx = 111.320 * cos(latitude * .pi / 180)
        let ky = 110.574
        return (0...segments).map { index in
            let angle = Double(index % segments) * 2 * .pi / Double(segments)
            return (latitude + radiusKm * sin(angle) / ky, longitude + radiusKm * cos(angle) / kx)
        }
    }

    /// "0.#" formatting like the Windows labels.
    static func km(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.targetId == rhs.targetId && lhs.revision == rhs.revision
    }
}

/// Triangulation layers currently on the map. In memory only — estimates are never
/// written to the node database.
@Observable
@MainActor
final class TriangulationMapStore {
    static let shared = TriangulationMapStore()

    static let palette = ["#D81B60", "#43A047", "#1E88E5", "#FB8C00", "#8E24AA", "#00ACC1", "#E53935"]

    private(set) var layers: [TriangulationMapLayer] = []
    /// Revision of the layer the maps should fit into view next; nil when handled.
    private(set) var focusRevision: Int?
    private var nextRevision = 1
    private var colorIndex = 0

    init() {}

    /// Adds the outcome as a layer, replacing an older one of the same target.
    func show(_ outcome: TriangulationOutcome, targetName: String) {
        let existingColor = layers.first { $0.targetId == outcome.targetId }?.colorHex
        let color = existingColor ?? Self.palette[colorIndex % Self.palette.count]
        if existingColor == nil { colorIndex += 1 }
        let layer = TriangulationMapLayer(
            targetId: outcome.targetId,
            targetName: targetName,
            colorHex: color,
            anchors: outcome.anchors,
            estimate: outcome.estimate,
            bandFactor: outcome.bandFactor,
            revision: nextRevision
        )
        nextRevision += 1
        layers.removeAll { $0.targetId == outcome.targetId }
        layers.append(layer)
        focusRevision = layer.revision
    }

    func remove(targetId: UInt32) {
        layers.removeAll { $0.targetId == targetId }
    }

    func clear() {
        layers.removeAll()
        focusRevision = nil
    }

    /// Called by a map after it fitted the requested layer into view.
    func consumeFocus(revision: Int) {
        if focusRevision == revision { focusRevision = nil }
    }
}
