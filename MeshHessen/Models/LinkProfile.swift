import Foundation

// Elevation profile of one RF link: terrain plus 4/3-earth bulge between two nodes, the
// line of sight between the antennas and the 60 % first-Fresnel-zone clearance at 868 MHz.
// Port of the Windows client's `LinkProfileWindow.xaml.cs` and the terrain helpers in
// `TriangulationService.cs` (`KnifeEdgeLossDb`, `PathFresnelV`, `PathExcessLossDb`).
// Pure math: elevation comes in as a sampler `(latitude, longitude) -> metres?`
// (e.g. `TerrainGrid.sampler`), so plan 029 can reuse the helpers directly.

/// Elevation sampler: metres above sea level, nil = no data.
typealias ElevationSampler = (_ latitude: Double, _ longitude: Double) -> Double?

/// A geographic point in degrees.
struct LinkProfilePoint: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// One sample along the path.
struct LinkProfileSample: Equatable, Sendable {
    /// Distance from the start in metres.
    let distance: Double
    /// Terrain height (m a.s.l.) without earth bulge.
    let terrain: Double
    /// Earth bulge (4/3 effective earth radius) in metres.
    let bulge: Double
    /// Height of the straight line between both antennas.
    let lineOfSight: Double
    /// Radius of the first Fresnel zone in metres.
    let fresnelRadius: Double

    /// Terrain as seen on the effective-earth profile (terrain + bulge).
    var ground: Double { terrain + bulge }
    /// Lower edge of the 60 % first Fresnel zone.
    var fresnelLowerEdge: Double { lineOfSight - 0.6 * fresnelRadius }
    /// Clearance below the 60 % Fresnel zone; > 0 = clear, < 0 = terrain intrudes.
    var margin: Double { fresnelLowerEdge - ground }
}

/// Overall assessment of a link.
enum LinkProfileVerdict: String, Equatable, Sendable {
    /// Line of sight and the 60 % Fresnel zone are free (no diffraction loss).
    case clear
    /// Line of sight is free but terrain intrudes into the 60 % Fresnel zone.
    case marginal
    /// Terrain touches or blocks the line of sight (knife-edge loss ≥ about 6 dB).
    case obstructed
    /// No elevation data for the path.
    case unknown
}

struct LinkProfileResult: Equatable, Sendable {
    /// Great-circle distance between both ends in metres.
    let distance: Double
    /// Samples with elevation data, ordered by distance (both endpoints included when known).
    let samples: [LinkProfileSample]
    /// Ground heights (m a.s.l.) at both ends; nil when unknown.
    let startElevation: Double?
    let endElevation: Double?
    /// Smallest clearance below the 60 % Fresnel zone over the inner samples (m).
    let worstMargin: Double?
    /// Where the smallest clearance occurs (m from the start).
    let worstMarginDistance: Double?
    /// Worst Fresnel–Kirchhoff parameter v along the path (−10 = clear/no data).
    let fresnelV: Double
    /// Estimated knife-edge diffraction loss in dB (0 = clear).
    let knifeEdgeLoss: Double
    let verdict: LinkProfileVerdict

    static func unknown(distance: Double) -> LinkProfileResult {
        LinkProfileResult(
            distance: distance,
            samples: [],
            startElevation: nil,
            endElevation: nil,
            worstMargin: nil,
            worstMarginDistance: nil,
            fresnelV: -10,
            knifeEdgeLoss: 0,
            verdict: .unknown
        )
    }
}

enum LinkProfile {
    /// Mesh Hessen LoRa frequency (EU 868).
    static let frequencyMHz = 868.0
    /// Default antenna height above ground: mesh nodes typically hang 2–3 m up.
    static let defaultAntennaHeight = 2.5
    /// 4/3 effective earth radius in metres (standard atmospheric refraction).
    static let effectiveEarthRadius = 4.0 / 3.0 * 6_371_000.0
    /// Samples used for drawing a profile.
    static let drawingSamples = 240
    /// Samples used for loss estimation in bulk (triangulation).
    static let estimationSamples = 24

    /// Wavelength in metres for a frequency in MHz.
    static func wavelength(frequencyMHz: Double = frequencyMHz) -> Double {
        299.792458 / frequencyMHz
    }

    /// Haversine distance in kilometres.
    static func haversineKm(_ latitude1: Double, _ longitude1: Double, _ latitude2: Double, _ longitude2: Double) -> Double {
        let radius = 6_371.0
        let deltaLatitude = (latitude2 - latitude1) * .pi / 180
        let deltaLongitude = (longitude2 - longitude1) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
            * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Knife edge / Fresnel (port of TriangulationService.cs)

    /// Knife-edge diffraction loss in dB for Fresnel parameter v (ITU-R P.526
    /// approximation). v ≤ −0.78 (≈ 60 % first-Fresnel-zone clearance) → 0 dB.
    static func knifeEdgeLossDb(_ v: Double) -> Double {
        guard v > -0.78 else { return 0 }
        return 6.9 + 20 * log10(sqrt((v - 0.1) * (v - 0.1) + 1) + v - 0.1)
    }

    /// Worst (maximum) Fresnel parameter v along the path between two antennas: terrain
    /// samples plus 4/3-earth bulge against the straight line of sight. Samples without
    /// elevation data are skipped; −10 = clear or no data.
    static func pathFresnelV(
        elevation: ElevationSampler,
        from start: LinkProfilePoint,
        antennaHeight startHeight: Double,
        to end: LinkProfilePoint,
        antennaHeight endHeight: Double,
        frequencyMHz: Double = frequencyMHz,
        samples: Int = estimationSamples
    ) -> Double {
        guard let geometry = PathGeometry(
            elevation: elevation, start: start, startHeight: startHeight,
            end: end, endHeight: endHeight, frequencyMHz: frequencyMHz
        ) else { return -10 }

        var worst = -10.0
        let count = max(samples, 2)
        for step in 1..<count {
            let t = Double(step) / Double(count)
            guard let terrain = elevation(geometry.latitude(at: t), geometry.longitude(at: t)) else { continue }
            let v = (terrain + geometry.bulge(at: t) - geometry.lineOfSight(at: t)) * geometry.vFactor(at: t)
            worst = max(worst, v)
        }
        return worst
    }

    /// Excess diffraction loss (dB) of the real terrain over the "typical link" baseline,
    /// where the ground runs straight between both endpoints' ground elevations. Empirical
    /// path-loss models already contain the usual near-ground Fresnel drag of a flat path,
    /// so only genuine terrain in the way (a ridge) yields a positive value. 0 = clear or no data.
    static func pathExcessLossDb(
        elevation: ElevationSampler,
        from start: LinkProfilePoint,
        antennaHeight startHeight: Double,
        to end: LinkProfilePoint,
        antennaHeight endHeight: Double,
        frequencyMHz: Double = frequencyMHz,
        samples: Int = estimationSamples
    ) -> Double {
        guard let geometry = PathGeometry(
            elevation: elevation, start: start, startHeight: startHeight,
            end: end, endHeight: endHeight, frequencyMHz: frequencyMHz
        ) else { return 0 }

        var worstReal = -10.0
        var worstBaseline = -10.0
        let count = max(samples, 2)
        for step in 1..<count {
            let t = Double(step) / Double(count)
            guard let terrain = elevation(geometry.latitude(at: t), geometry.longitude(at: t)) else { continue }
            let bulge = geometry.bulge(at: t)
            let lineOfSight = geometry.lineOfSight(at: t)
            let factor = geometry.vFactor(at: t)
            worstReal = max(worstReal, (terrain + bulge - lineOfSight) * factor)
            let baselineGround = geometry.startGround + (geometry.endGround - geometry.startGround) * t
            worstBaseline = max(worstBaseline, (baselineGround + bulge - lineOfSight) * factor)
        }
        return max(0, knifeEdgeLossDb(worstReal) - knifeEdgeLossDb(worstBaseline))
    }

    // MARK: - Profile

    /// Full profile for drawing plus the verdict. Points are interpolated linearly in
    /// latitude/longitude between both ends (as the Windows client does; for LoRa link
    /// lengths this is indistinguishable from the great circle).
    static func compute(
        from start: LinkProfilePoint,
        to end: LinkProfilePoint,
        antennaHeights: (start: Double, end: Double) = (defaultAntennaHeight, defaultAntennaHeight),
        elevation: ElevationSampler?,
        samples: Int = drawingSamples,
        frequencyMHz: Double = frequencyMHz
    ) -> LinkProfileResult {
        let distance = haversineKm(start.latitude, start.longitude, end.latitude, end.longitude) * 1_000
        guard let elevation,
              let startGround = elevation(start.latitude, start.longitude),
              let endGround = elevation(end.latitude, end.longitude) else {
            return .unknown(distance: distance)
        }

        let count = max(samples, 2)
        let lambda = wavelength(frequencyMHz: frequencyMHz)
        let startAntenna = startGround + antennaHeights.start
        let endAntenna = endGround + antennaHeights.end

        var points: [LinkProfileSample] = []
        points.reserveCapacity(count + 1)
        var worstMargin: Double?
        var worstMarginDistance: Double?
        for step in 0...count {
            let t = Double(step) / Double(count)
            let latitude = start.latitude + (end.latitude - start.latitude) * t
            let longitude = start.longitude + (end.longitude - start.longitude) * t
            guard let terrain = elevation(latitude, longitude) else { continue }

            let d1 = max(distance * t, 1)
            let d2 = max(distance * (1 - t), 1)
            let sample = LinkProfileSample(
                distance: distance * t,
                terrain: terrain,
                bulge: d1 * d2 / (2 * effectiveEarthRadius),
                lineOfSight: startAntenna + (endAntenna - startAntenna) * t,
                fresnelRadius: distance > 0 ? sqrt(lambda * d1 * d2 / distance) : 0
            )
            points.append(sample)
            if step > 0, step < count, sample.margin < (worstMargin ?? .infinity) {
                worstMargin = sample.margin
                worstMarginDistance = sample.distance
            }
        }

        let v = pathFresnelV(
            elevation: elevation,
            from: start, antennaHeight: antennaHeights.start,
            to: end, antennaHeight: antennaHeights.end,
            frequencyMHz: frequencyMHz,
            samples: count
        )
        let loss = knifeEdgeLossDb(v)
        let verdict: LinkProfileVerdict
        if loss <= 0 {
            verdict = .clear
        } else if v < 0 {
            verdict = .marginal
        } else {
            verdict = .obstructed
        }

        return LinkProfileResult(
            distance: distance,
            samples: points,
            startElevation: startGround,
            endElevation: endGround,
            worstMargin: worstMargin,
            worstMarginDistance: worstMarginDistance,
            fresnelV: v,
            knifeEdgeLoss: loss,
            verdict: verdict
        )
    }

    // MARK: - Private

    /// Shared geometry of the C# helpers (antenna heights, LOS, bulge, v factor).
    private struct PathGeometry {
        let start: LinkProfilePoint
        let end: LinkProfilePoint
        let startGround: Double
        let endGround: Double
        let startAntenna: Double
        let endAntenna: Double
        let distance: Double
        let lambda: Double

        init?(
            elevation: ElevationSampler,
            start: LinkProfilePoint,
            startHeight: Double,
            end: LinkProfilePoint,
            endHeight: Double,
            frequencyMHz: Double
        ) {
            guard let startGround = elevation(start.latitude, start.longitude),
                  let endGround = elevation(end.latitude, end.longitude) else { return nil }
            let distance = LinkProfile.haversineKm(start.latitude, start.longitude, end.latitude, end.longitude) * 1_000
            guard distance >= 50 else { return nil }   // effectively co-located
            self.start = start
            self.end = end
            self.startGround = startGround
            self.endGround = endGround
            self.startAntenna = startGround + startHeight
            self.endAntenna = endGround + endHeight
            self.distance = distance
            self.lambda = LinkProfile.wavelength(frequencyMHz: frequencyMHz)
        }

        func latitude(at t: Double) -> Double { start.latitude + (end.latitude - start.latitude) * t }
        func longitude(at t: Double) -> Double { start.longitude + (end.longitude - start.longitude) * t }
        func lineOfSight(at t: Double) -> Double { startAntenna + (endAntenna - startAntenna) * t }

        func bulge(at t: Double) -> Double {
            distance * t * distance * (1 - t) / (2 * LinkProfile.effectiveEarthRadius)
        }

        func vFactor(at t: Double) -> Double {
            sqrt(2 * distance / (lambda * distance * t * distance * (1 - t)))
        }
    }
}

extension LinkProfile {
    /// Convenience: profile against a loaded terrain grid (nil grid → `.unknown`).
    static func compute(
        from start: LinkProfilePoint,
        to end: LinkProfilePoint,
        antennaHeights: (start: Double, end: Double) = (defaultAntennaHeight, defaultAntennaHeight),
        grid: TerrainGrid?,
        samples: Int = drawingSamples
    ) -> LinkProfileResult {
        compute(
            from: start,
            to: end,
            antennaHeights: antennaHeights,
            elevation: grid.map { grid in { grid.height(latitude: $0, longitude: $1) } },
            samples: samples
        )
    }
}
