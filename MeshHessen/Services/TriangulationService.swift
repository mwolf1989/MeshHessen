import Foundation

/// Position estimation from RF-link neighbours: signal → distance model plus robust
/// trilateration. Pure math without UI or database dependencies.
///
/// Port of the Windows `TriangulationService.cs` (1.7.0); constants must stay identical.
/// The result is always a rough estimate — terrain dominates LoRa links.
enum TriangulationService {

    /// One distance circle.
    ///
    /// - `posErrKm`: the anchor's own position uncertainty (e.g. precision-bits truncation);
    ///   within that radius the cost function applies no penalty (dead zone).
    /// - `weightScale`: boosts hard information (a reported-position prior outranks RF guesses).
    /// - `sigmaKm`: expected 1-σ error of `distKm` itself; 0 derives a default (30 % of the
    ///   distance, at least 0.3 km). Residuals are normalised by it.
    struct Anchor: Equatable, Sendable {
        var lat: Double
        var lon: Double
        var distKm: Double
        var posErrKm: Double = 0
        var weightScale: Double = 1
        var sigmaKm: Double = 0
    }

    // MARK: - Link budget (expert corrections)

    /// Implicit link budget of the distance model: 22 dBm TX + 1 dBi antenna on each end.
    static let referenceTxDbm = 22.0
    static let referenceAntennaDbi = 1.0

    /// Adjusts a measured RSSI to the reference link budget before the distance model is
    /// applied: the transmitter's power and antenna gain plus the receiver's antenna gain,
    /// relative to 22 dBm + 1 dBi + 1 dBi. A hotter link yields a lower effective RSSI.
    static func adjustedRssi(_ rssi: Double, txDbm: Double, txAntennaDbi: Double, rxAntennaDbi: Double) -> Double {
        rssi - ((txDbm + txAntennaDbi + rxAntennaDbi) - (referenceTxDbm + 2 * referenceAntennaDbi))
    }

    /// Typical maximum TX power (dBm) by hardware model string — a starting value only.
    static func txPresetDbm(_ hardwareModel: String?) -> Double {
        let model = (hardwareModel ?? "").uppercased().replacingOccurrences(of: "_", with: "")
        if model.contains("WISMESH") { return 27 }
        if model.contains("RAK") { return 22 }
        if model.contains("STATION") { return 30 }
        if model.contains("HELTEC") && model.contains("V4") { return 27 }
        if model.contains("HELTEC") { return 21 }
        if model.contains("TBEAM") { return 22 }
        if model.contains("TLORA") { return 21 }
        if model.contains("TDECK") { return 22 }
        if model.contains("TECHO") { return 22 }
        return 20
    }

    static func dbmToWatts(_ dbm: Double) -> Double {
        pow(10, dbm / 10) / 1000
    }

    // MARK: - Robust link value

    /// Sorts, trims `trimFraction` off each end (rounded down, so small samples are a plain
    /// median) and returns the median of the rest; nil when empty.
    static func trimmedMedian(_ values: [Double], trimFraction: Double = 0.05) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        var trim = Int(Double(sorted.count) * trimFraction)
        if sorted.count - 2 * trim < 1 { trim = (sorted.count - 1) / 2 }
        let kept = Array(sorted[trim..<(sorted.count - trim)])
        let mid = kept.count / 2
        return kept.count % 2 == 1 ? kept[mid] : (kept[mid - 1] + kept[mid]) / 2
    }

    // MARK: - Terrain (line of sight / Fresnel)

    /// Default antenna height above ground (m).
    static let defaultAntennaHeightM = 2.5

    /// Terrain context for `estimate`: elevation sampler (m a.s.l., nil = no data), antenna
    /// heights above ground (parallel to the anchor list) and the path-loss exponent that
    /// converts diffraction loss into the model's signal-distance space.
    struct TerrainContext {
        var elevationAt: (Double, Double) -> Double?
        var anchorHeightM: [Double]
        var targetHeightM: Double = TriangulationService.defaultAntennaHeightM
        var exponent: Double = 2.5
        var freqMhz: Double = 868
    }

    // Knife edge / Fresnel: one implementation, in `LinkProfile` (plan 028). These
    // forwarders keep the C#-shaped signatures the solver and its ported tests use.

    /// Knife-edge diffraction loss in dB for Fresnel parameter v (ITU-R P.526 approximation).
    static func knifeEdgeLossDb(_ v: Double) -> Double {
        LinkProfile.knifeEdgeLossDb(v)
    }

    /// Worst Fresnel parameter v along the path (terrain plus 4/3-earth bulge against the
    /// line of sight). Samples without data are skipped; −10 = clear or no data.
    static func pathFresnelV(
        _ elevation: (Double, Double) -> Double?,
        lat1: Double, lon1: Double, h1AglM: Double,
        lat2: Double, lon2: Double, h2AglM: Double,
        freqMhz: Double = 868, samples: Int = 24
    ) -> Double {
        withoutActuallyEscaping(elevation) { sampler in
            LinkProfile.pathFresnelV(
                elevation: sampler,
                from: LinkProfilePoint(latitude: lat1, longitude: lon1), antennaHeight: h1AglM,
                to: LinkProfilePoint(latitude: lat2, longitude: lon2), antennaHeight: h2AglM,
                frequencyMHz: freqMhz, samples: samples
            )
        }
    }

    /// Excess diffraction loss (dB) of the real terrain over a straight ground line between
    /// the endpoints. The empirical model already contains a flat path's near-ground drag,
    /// so only terrain genuinely in the way counts. 0 = clear or no data.
    static func pathExcessLossDb(
        _ elevation: (Double, Double) -> Double?,
        lat1: Double, lon1: Double, h1AglM: Double,
        lat2: Double, lon2: Double, h2AglM: Double,
        freqMhz: Double = 868, samples: Int = 24
    ) -> Double {
        withoutActuallyEscaping(elevation) { sampler in
            LinkProfile.pathExcessLossDb(
                elevation: sampler,
                from: LinkProfilePoint(latitude: lat1, longitude: lon1), antennaHeight: h1AglM,
                to: LinkProfilePoint(latitude: lat2, longitude: lon2), antennaHeight: h2AglM,
                frequencyMHz: freqMhz, samples: samples
            )
        }
    }

    /// Haversine distance in km.
    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Half-cell position error (km) of a precision-bits-truncated position:
    /// 2^(32−bits) · 1e-7° · 111.32 km/° / 2. 32 (or unknown/0) = exact.
    static func precisionBitsToKm(_ bits: Int) -> Double {
        bits <= 0 || bits >= 32 ? 0 : pow(2, Double(32 - bits)) * 1e-7 * 111.32 / 2
    }

    // MARK: - Distance model

    /// Path-loss model: expected RSSI at 1 km, exponent, residual spread (dB), fit quality.
    /// `clamped` = the raw fit ran into the physical bounds (degenerate).
    struct Calibration: Equatable, Sendable {
        var p1Km: Double
        var exponent: Double
        var samples: Int
        var sigmaDb: Double = 6
        var r2: Double = 0
        var clamped = false

        static let `default` = Calibration(p1Km: -90, exponent: 2.5, samples: 0)

        var isFitted: Bool { samples > 0 }
    }

    /// Multiplicative distance uncertainty of the model (never below 1.5).
    static func distanceFactor(_ calibration: Calibration = .default) -> Double {
        max(pow(10, calibration.sigmaDb / (10 * calibration.exponent)), 1.5)
    }

    /// d = 10^((P1km − RSSI) / (10·n)) km, clamped to 0.3–60 km.
    static func signalDistanceKm(_ rssiEstimate: Double, _ calibration: Calibration = .default) -> Double {
        min(max(pow(10, (calibration.p1Km - rssiEstimate) / (10 * calibration.exponent)), 0.3), 60)
    }

    /// Self-calibration from links whose both ends have a known position. OLS of RSSI on
    /// log10(d); falls back to the default with fewer than 8 samples, a max/min distance
    /// ratio below 3 or a non-negative slope. Fitted values are clamped to sane RF ranges.
    static func fitCalibration(_ samples: [(distKm: Double, rssi: Double)]) -> Calibration {
        let valid = samples.filter { $0.distKm >= 0.2 && $0.distKm <= 80 }
        guard valid.count >= 8,
              let maxDistance = valid.map(\.distKm).max(),
              let minDistance = valid.map(\.distKm).min(),
              maxDistance / minDistance >= 3 else { return .default }

        let xs = valid.map { log10($0.distKm) }
        let ys = valid.map(\.rssi)
        let count = Double(valid.count)
        let mx = xs.reduce(0, +) / count, my = ys.reduce(0, +) / count
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        if sxx < 1e-9 { return .default }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let b = sxy / sxx
        let a = my - b * mx

        if b >= 0 { return .default }

        let ssTot = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        let ssRes = zip(xs, ys).reduce(0) { sum, pair in
            let error = pair.1 - (a + b * pair.0)
            return sum + error * error
        }
        let r2 = ssTot > 1e-9 ? 1 - ssRes / ssTot : 0

        let rmse = sqrt(ssRes / count)
        let nRaw = -b / 10
        let n = min(max(nRaw, 1.8), 4.5)
        let p1 = min(max(a, -110), -70)
        let clamped = abs(n - nRaw) > 1e-9 || abs(p1 - a) > 1e-9
        return Calibration(
            p1Km: p1,
            exponent: n,
            samples: valid.count,
            sigmaDb: min(max(rmse, 3), 12),
            r2: r2,
            clamped: clamped
        )
    }

    // MARK: - Solver

    /// Best position, uncertainty radius and — when the cost landscape has a second
    /// plausible region — an alternative candidate.
    struct EstimateResult: Equatable, Sendable {
        var lat: Double
        var lon: Double
        var uncertaintyKm: Double
        var altLat: Double?
        var altLon: Double?

        var hasAlternative: Bool { altLat != nil && altLon != nil }
    }

    /// Best position only; nil without anchors.
    static func trilaterate(_ anchors: [Anchor]) -> (lat: Double, lon: Double)? {
        estimate(anchors).map { ($0.lat, $0.lon) }
    }

    /// Geographic bounding box of the grid scan (each anchor padded by distance + position
    /// error) — the region a terrain grid must cover.
    static func searchBounds(_ anchors: [Anchor]) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        guard !anchors.isEmpty else { return nil }
        let lat0 = anchors.map(\.lat).reduce(0, +) / Double(anchors.count)
        let kx = 111.320 * cos(lat0 * .pi / 180)
        let ky = 110.574
        return (
            anchors.map { $0.lat - ($0.distKm + $0.posErrKm) / ky }.min() ?? 0,
            anchors.map { $0.lon - ($0.distKm + $0.posErrKm) / kx }.min() ?? 0,
            anchors.map { $0.lat + ($0.distKm + $0.posErrKm) / ky }.max() ?? 0,
            anchors.map { $0.lon + ($0.distKm + $0.posErrKm) / kx }.max() ?? 0
        )
    }

    /// Diffraction loss cap: coarse terrain data cannot justify more for a link that exists.
    static let maxDiffractionDb = 25.0

    /// Robust estimate: Huber loss (K = 1.5) on `(|r − d| − E) / σ`, 81×81 grid scan, then
    /// normalised gradient descent. Nil without anchors.
    static func estimate(_ anchors: [Anchor], terrain: TerrainContext? = nil) -> EstimateResult? {
        guard let first = anchors.first else { return nil }
        if anchors.count == 1 {
            return EstimateResult(lat: first.lat, lon: first.lon, uncertaintyKm: first.distKm + first.posErrKm)
        }

        let lat0 = anchors.map(\.lat).reduce(0, +) / Double(anchors.count)
        let kx = 111.320 * cos(lat0 * .pi / 180)
        let ky = 110.574
        let refLat = first.lat, refLon = first.lon

        struct Point { let x, y, d, e, s, w: Double }
        let points = anchors.map { anchor in
            Point(
                x: (anchor.lon - refLon) * kx,
                y: (anchor.lat - refLat) * ky,
                d: anchor.distKm,
                e: max(anchor.posErrKm, 0),
                s: anchor.sigmaKm > 0 ? anchor.sigmaKm : max(0.3 * anchor.distKm, 0.3),
                w: max(anchor.weightScale, 0.01)
            )
        }

        let huberK = 1.5

        func cost(_ px: Double, _ py: Double) -> Double {
            var sum = 0.0
            let cellLat = refLat + py / ky, cellLon = refLon + px / kx
            for (index, point) in points.enumerated() {
                var r = sqrt((px - point.x) * (px - point.x) + (py - point.y) * (py - point.y))
                if let terrain, point.d >= 0.05 {
                    let loss = min(pathExcessLossDb(
                        terrain.elevationAt,
                        lat1: cellLat, lon1: cellLon, h1AglM: terrain.targetHeightM,
                        lat2: anchors[index].lat, lon2: anchors[index].lon, h2AglM: terrain.anchorHeightM[index],
                        freqMhz: terrain.freqMhz
                    ), maxDiffractionDb)
                    if loss > 0 { r *= pow(10, loss / (10 * terrain.exponent)) }
                }
                let e = max(abs(r - point.d) - point.e, 0) / point.s
                let c = e <= huberK ? e * e : huberK * (2 * e - huberK)
                sum += point.w * c
            }
            return sum
        }

        typealias Cell = (x: Double, y: Double, f: Double)

        let maxDistance = points.map(\.d).max() ?? 0
        func descend(_ sx: Double, _ sy: Double) -> Cell {
            var x = sx, y = sy, f = cost(sx, sy)
            var step = max(maxDistance * 0.25, 1.0)
            var iteration = 0
            while iteration < 300 && step > 0.002 {
                iteration += 1
                let h = 0.01
                let gx = (cost(x + h, y) - cost(x - h, y)) / (2 * h)
                let gy = (cost(x, y + h) - cost(x, y - h)) / (2 * h)
                let gl = sqrt(gx * gx + gy * gy)
                if gl < 1e-9 { break }
                let nx = x - step * gx / gl, ny = y - step * gy / gl
                let nf = cost(nx, ny)
                if nf < f {
                    x = nx; y = ny; f = nf
                } else {
                    step *= 0.5
                }
            }
            return (x, y, f)
        }

        let minX = points.map { $0.x - $0.d - $0.e }.min() ?? 0
        let maxX = points.map { $0.x + $0.d + $0.e }.max() ?? 0
        let minY = points.map { $0.y - $0.d - $0.e }.min() ?? 0
        let maxY = points.map { $0.y + $0.d + $0.e }.max() ?? 0
        let gridSize = 81
        let stepX = (maxX - minX) / Double(gridSize - 1), stepY = (maxY - minY) / Double(gridSize - 1)
        let gridStep = max(stepX, stepY)

        var cells: [Cell] = []
        cells.reserveCapacity(gridSize * gridSize)
        var bestCell: Cell = (minX, minY, .greatestFiniteMagnitude)
        for iy in 0..<gridSize {
            for ix in 0..<gridSize {
                let cx = minX + Double(ix) * stepX, cy = minY + Double(iy) * stepY
                let cf = cost(cx, cy)
                cells.append((cx, cy, cf))
                if cf < bestCell.f { bestCell = (cx, cy, cf) }
            }
        }

        let best = descend(bestCell.x, bestCell.y)

        let threshold = best.f * 1.6 + 0.02
        let accepted = cells.filter { $0.f <= threshold }

        func distance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by))
        }
        let altMinDistance = max(3.0, 4 * gridStep)
        var alternative: Cell?
        let altSeed = accepted
            .filter { distance($0.x, $0.y, best.x, best.y) > altMinDistance && $0.f <= best.f * 1.4 + 0.02 }
            .min { $0.f < $1.f }
        if let altSeed {
            let refined = descend(altSeed.x, altSeed.y)
            if distance(refined.x, refined.y, best.x, best.y) > altMinDistance {
                alternative = refined
            }
        }

        let mainDistances = accepted
            .filter { cell in
                guard let alternative else { return true }
                return distance(cell.x, cell.y, best.x, best.y)
                    <= distance(cell.x, cell.y, alternative.x, alternative.y)
            }
            .map { distance($0.x, $0.y, best.x, best.y) }
            .sorted()
        let uncertainty = mainDistances.isEmpty
            ? gridStep
            : max(mainDistances[Int(Double(mainDistances.count - 1) * 0.9)], gridStep)

        return EstimateResult(
            lat: refLat + best.y / ky,
            lon: refLon + best.x / kx,
            uncertaintyKm: uncertainty,
            altLat: alternative.map { refLat + $0.y / ky },
            altLon: alternative.map { refLon + $0.x / kx }
        )
    }
}
