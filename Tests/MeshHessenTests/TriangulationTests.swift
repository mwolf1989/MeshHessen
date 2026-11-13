import Foundation
import Testing

@testable import MeshHessen

private typealias Tri = TriangulationService
private typealias Anchor = TriangulationService.Anchor

/// Planar km distance (same projection as the solver).
private func distKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let kx = 111.320 * cos(((lat1 + lat2) / 2) * .pi / 180)
    let dx = (lon2 - lon1) * kx, dy = (lat2 - lat1) * 110.574
    return sqrt(dx * dx + dy * dy)
}

/// xUnit `Assert.Equal(expected, actual, precision: n)` — both rounded to n decimals.
private func equal(_ actual: Double, _ expected: Double, precision: Int) -> Bool {
    let scale = pow(10, Double(precision))
    return (actual * scale).rounded() == (expected * scale).rounded()
}

/// .NET `new Random(seed)` (legacy seeded Knuth subtractive generator), so the
/// "uncorrelated noise" test sees exactly the samples of the Windows test.
private struct DotNetRandom {
    private static let mbig = Int(Int32.max)
    private static let mseed = 161_803_398
    private var seedArray = [Int](repeating: 0, count: 56)
    private var inext = 0
    private var inextp = 21

    init(seed: Int32) {
        let subtraction = seed == Int32.min ? Int(Int32.max) : abs(Int(seed))
        var mj = Self.mseed - subtraction
        seedArray[55] = mj
        var mk = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21
            if ii >= 55 { ii -= 55 }
            seedArray[ii] = mk
            mk = mj - mk
            if mk < 0 { mk += Self.mbig }
            mj = seedArray[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30
                if n >= 55 { n -= 55 }
                seedArray[i] -= seedArray[1 + n]
                if seedArray[i] < 0 { seedArray[i] += Self.mbig }
            }
        }
    }

    mutating func nextDouble() -> Double {
        var locINext = inext + 1
        if locINext >= 56 { locINext = 1 }
        var locINextp = inextp + 1
        if locINextp >= 56 { locINextp = 1 }
        var value = seedArray[locINext] - seedArray[locINextp]
        if value == Self.mbig { value -= 1 }
        if value < 0 { value += Self.mbig }
        seedArray[locINext] = value
        inext = locINext
        inextp = locINextp
        return Double(value) * (1.0 / Double(Self.mbig))
    }
}

private let alsfeldTruth = (lat: 50.75, lon: 9.27)
private let surroundingAnchors: [(lat: Double, lon: Double)] = [(50.90, 9.10), (50.60, 9.20), (50.80, 9.55)]

private func exactAnchors(_ positions: [(lat: Double, lon: Double)], truth: (lat: Double, lon: Double)) -> [Anchor] {
    positions.map { Anchor(lat: $0.lat, lon: $0.lon, distKm: distKm($0.lat, $0.lon, truth.lat, truth.lon)) }
}

/// Port of the Windows `TriangulationTests.cs` (1:1, same inputs and tolerances).
@Suite("Triangulation")
struct TriangulationTests {

    // MARK: - Distance model and trilateration

    @Test("Distance model is monotonic and calibrated")
    func distanceModelIsMonotonicAndCalibrated() {
        #expect(equal(Tri.signalDistanceKm(-90), 1.0, precision: 3))
        #expect(Tri.signalDistanceKm(-115) > Tri.signalDistanceKm(-100))
        #expect(Tri.signalDistanceKm(-100) > Tri.signalDistanceKm(-85))
        #expect(equal(Tri.signalDistanceKm(-20), 0.3, precision: 3))
        #expect(equal(Tri.signalDistanceKm(-170), 60.0, precision: 3))
    }

    @Test("Trilateration recovers the position from exact distances")
    func trilaterationRecoversExactPosition() throws {
        let estimate = try #require(Tri.trilaterate(exactAnchors(surroundingAnchors, truth: alsfeldTruth)))
        let error = distKm(estimate.lat, estimate.lon, alsfeldTruth.lat, alsfeldTruth.lon)
        #expect(error < 0.5, "estimate off by \(error) km")
    }

    @Test("Trilateration with noisy distances stays in the plausible region")
    func trilaterationWithNoisyDistances() throws {
        let positions: [(lat: Double, lon: Double)] = [(50.90, 9.10), (50.60, 9.20), (50.80, 9.55), (50.70, 9.00)]
        let noise = [1.4, 0.7, 1.25, 0.8]
        let anchors = positions.enumerated().map { index, position in
            Anchor(
                lat: position.lat,
                lon: position.lon,
                distKm: distKm(position.lat, position.lon, alsfeldTruth.lat, alsfeldTruth.lon) * noise[index]
            )
        }
        let estimate = try #require(Tri.trilaterate(anchors))
        let error = distKm(estimate.lat, estimate.lon, alsfeldTruth.lat, alsfeldTruth.lon)
        #expect(error < 8, "estimate off by \(error) km")
    }

    @Test("Two anchors give a point between or near them")
    func twoAnchorsGiveAPointBetween() throws {
        let estimate = try #require(Tri.trilaterate([
            Anchor(lat: 50.0, lon: 9.0, distKm: 5),
            Anchor(lat: 50.0, lon: 9.3, distKm: 5),
        ]))
        #expect((9.0...9.3).contains(estimate.lon))
        #expect((49.9...50.1).contains(estimate.lat))
    }

    @Test("A single anchor returns the anchor position")
    func singleAnchorReturnsAnchorPosition() throws {
        let estimate = try #require(Tri.trilaterate([Anchor(lat: 51.1, lon: 8.8, distKm: 10)]))
        #expect(equal(estimate.lat, 51.1, precision: 6))
        #expect(equal(estimate.lon, 8.8, precision: 6))
    }

    @Test("No anchors give no estimate")
    func noAnchorsGiveNoEstimate() {
        #expect(Tri.estimate([]) == nil)
    }

    // MARK: - Uncertainty and ambiguity

    @Test("Surrounding anchors with exact distances give a tight, unambiguous estimate")
    func surroundingAnchorsGiveTightEstimate() throws {
        let estimate = try #require(Tri.estimate(exactAnchors(surroundingAnchors, truth: alsfeldTruth)))
        #expect(distKm(estimate.lat, estimate.lon, alsfeldTruth.lat, alsfeldTruth.lon) < 0.6)
        #expect(estimate.uncertaintyKm < 2.5, "uncertainty \(estimate.uncertaintyKm) km")
        #expect(!estimate.hasAlternative)
    }

    @Test("Colinear anchors report the mirror position as alternative")
    func colinearAnchorsReportMirror() throws {
        let truth = (lat: 50.08, lon: 9.10)
        let estimate = try #require(Tri.estimate(exactAnchors([(50.0, 9.0), (50.0, 9.1), (50.0, 9.2)], truth: truth)))
        #expect(estimate.hasAlternative, "mirror ambiguity should be detected")
        let altLat = try #require(estimate.altLat)
        let altLon = try #require(estimate.altLon)
        let dMain = distKm(estimate.lat, estimate.lon, truth.lat, truth.lon)
        let dAlt = distKm(altLat, altLon, truth.lat, truth.lon)
        #expect(min(dMain, dAlt) < 1.5, "neither candidate near truth (\(dMain)/\(dAlt) km)")
        #expect(max(dMain, dAlt) > 10, "candidates should be on opposite sides of the line")
    }

    @Test("Inconsistent distances increase the uncertainty")
    func inconsistentDistancesIncreaseUncertainty() throws {
        let exact = exactAnchors(surroundingAnchors, truth: alsfeldTruth)
        let noise = [1.6, 0.6, 1.3]
        let noisy = exact.enumerated().map { index, anchor in
            Anchor(lat: anchor.lat, lon: anchor.lon, distKm: anchor.distKm * noise[index])
        }
        let noisyEstimate = try #require(Tri.estimate(noisy))
        let exactEstimate = try #require(Tri.estimate(exact))
        #expect(noisyEstimate.uncertaintyKm > exactEstimate.uncertaintyKm,
                "contradictory distances must widen the uncertainty region")
    }

    @Test("Distance factor reflects the model sigma and has a floor")
    func distanceFactorReflectsSigma() {
        #expect(Tri.distanceFactor() >= 1.5)
        let tight = Tri.Calibration(p1Km: -90, exponent: 2.5, samples: 20, sigmaDb: 3)
        let loose = Tri.Calibration(p1Km: -90, exponent: 2.5, samples: 20, sigmaDb: 10)
        #expect(Tri.distanceFactor(loose) > Tri.distanceFactor(tight))
    }

    // MARK: - Trimmed median

    @Test("Trimmed median handles empty and single input")
    func trimmedMedianHandlesEmptyAndSingle() throws {
        #expect(Tri.trimmedMedian([]) == nil)
        #expect(equal(try #require(Tri.trimmedMedian([-7.5])), -7.5, precision: 6))
    }

    @Test("Trimmed median is the plain median for small samples")
    func trimmedMedianIsMedianForSmallSamples() throws {
        #expect(equal(try #require(Tri.trimmedMedian([9, 1, 5])), 5, precision: 6))
        #expect(equal(try #require(Tri.trimmedMedian([4, 1, 2, 8])), 3, precision: 6))
    }

    @Test("Trimmed median discards outliers")
    func trimmedMedianDiscardsOutliers() throws {
        let values = Array(repeating: -95.0, count: 18) + [-160, -20]
        #expect(equal(try #require(Tri.trimmedMedian(values)), -95, precision: 6))
    }

    // MARK: - Robust estimation and degenerate fits

    @Test("One outlier anchor cannot drag the estimate")
    func oneOutlierCannotDragEstimate() throws {
        let consistent = [
            Anchor(lat: 50.0, lon: 8.000, distKm: 2.0),
            Anchor(lat: 50.0, lon: 8.056, distKm: 2.0),
        ]
        let withOutlier = consistent + [Anchor(lat: 50.0, lon: 8.400, distKm: 3.0)]
        let clean = try #require(Tri.estimate(consistent))
        let robust = try #require(Tri.estimate(withOutlier))
        let kx = 111.32 * cos(50 * Double.pi / 180)
        let shiftKm = sqrt(
            pow((robust.lat - clean.lat) * 110.574, 2) + pow((robust.lon - clean.lon) * kx, 2)
        )
        #expect(shiftKm < 1.5, "outlier shifted the estimate by \(shiftKm) km")
    }

    @Test("A fit running into the parameter bounds is flagged as clamped")
    func fitIntoBoundsIsClamped() {
        let flat = (0..<20).map { index in (distKm: 0.5 + Double(index) * 0.8, rssi: -95 + Double(index % 2)) }
        let calibration = Tri.fitCalibration(flat)
        if calibration.isFitted { #expect(calibration.clamped, "degenerate fit must be flagged") }

        let good = (0..<20).map { index -> (distKm: Double, rssi: Double) in
            let d = 0.5 + Double(index) * 0.7
            return (d, -90 - 25 * log10(d))
        }
        let goodCalibration = Tri.fitCalibration(good)
        #expect(goodCalibration.isFitted)
        #expect(!goodCalibration.clamped)
    }

    // MARK: - Terrain

    @Test("Knife-edge loss is zero when clear and grows with v")
    func knifeEdgeLoss() {
        #expect(equal(Tri.knifeEdgeLossDb(-1), 0, precision: 6))
        #expect(equal(Tri.knifeEdgeLossDb(-0.79), 0, precision: 6))
        #expect(abs(Tri.knifeEdgeLossDb(0) - 6.0) <= 0.1)
        #expect(Tri.knifeEdgeLossDb(1) > Tri.knifeEdgeLossDb(0))
        #expect(Tri.knifeEdgeLossDb(3) > Tri.knifeEdgeLossDb(1))
    }

    @Test("Flat terrain has no excess loss")
    func flatTerrainHasNoExcessLoss() {
        let flat: (Double, Double) -> Double? = { _, _ in 100 }
        let excess = Tri.pathExcessLossDb(flat, lat1: 50.0, lon1: 8.0, h1AglM: 2.5, lat2: 50.0, lon2: 8.14, h2AglM: 2.5)
        #expect(equal(excess, 0, precision: 6))
        #expect(Tri.pathFresnelV(flat, lat1: 50.0, lon1: 8.0, h1AglM: 2.5, lat2: 50.0, lon2: 8.14, h2AglM: 2.5) > -0.78)
    }

    @Test("A ridge between the endpoints yields excess loss")
    func ridgeYieldsExcessLoss() {
        let ridge: (Double, Double) -> Double? = { _, lon in lon > 8.06 && lon < 8.08 ? 300 : 100 }
        let excess = Tri.pathExcessLossDb(ridge, lat1: 50.0, lon1: 8.0, h1AglM: 2.5, lat2: 50.0, lon2: 8.14, h2AglM: 2.5)
        #expect(excess > 6, "expected clearly positive excess loss, got \(excess) dB")
        let beyond = Tri.pathExcessLossDb(ridge, lat1: 50.0, lon1: 8.09, h1AglM: 2.5, lat2: 50.0, lon2: 8.14, h2AglM: 2.5)
        #expect(equal(beyond, 0, precision: 6))
    }

    @Test("No elevation data means no penalty")
    func noElevationDataMeansNoPenalty() {
        let none: (Double, Double) -> Double? = { _, _ in nil }
        let excess = Tri.pathExcessLossDb(none, lat1: 50.0, lon1: 8.0, h1AglM: 2.5, lat2: 50.0, lon2: 8.14, h2AglM: 2.5)
        #expect(equal(excess, 0, precision: 6))
    }

    @Test("Terrain breaks the mirror ambiguity toward the clear side")
    func terrainBreaksMirrorAmbiguity() throws {
        let anchors = [
            Anchor(lat: 50.0, lon: 8.00, distKm: 6.0),
            Anchor(lat: 50.0, lon: 8.14, distKm: 6.0),
        ]
        let terrain = Tri.TerrainContext(
            elevationAt: { lat, _ in lat > 50.02 ? 400 : 100 },
            anchorHeightM: [2.5, 2.5],
            targetHeightM: 2.5
        )
        let estimate = try #require(Tri.estimate(anchors, terrain: terrain))
        #expect(estimate.lat < 50.0, "estimate should be south of the anchor line, got \(estimate.lat)")
    }

    // MARK: - Link budget

    @Test("The reference link budget is a no-op")
    func referenceLinkBudgetIsNoop() {
        let adjusted = Tri.adjustedRssi(
            -100,
            txDbm: Tri.referenceTxDbm,
            txAntennaDbi: Tri.referenceAntennaDbi,
            rxAntennaDbi: Tri.referenceAntennaDbi
        )
        #expect(equal(adjusted, -100, precision: 6))
    }

    @Test("A stronger transmitter yields a larger distance")
    func strongerTransmitterYieldsLargerDistance() {
        let adjusted = Tri.adjustedRssi(-100, txDbm: 30, txAntennaDbi: 3, rxAntennaDbi: Tri.referenceAntennaDbi)
        #expect(equal(adjusted, -110, precision: 6))
        #expect(Tri.signalDistanceKm(adjusted) > Tri.signalDistanceKm(-100))
    }

    @Test("RX antenna gain counts like TX gain")
    func rxAntennaGainCountsLikeTxGain() {
        #expect(equal(Tri.adjustedRssi(-100, txDbm: 22, txAntennaDbi: 1, rxAntennaDbi: 7), -106, precision: 6))
        #expect(equal(
            Tri.adjustedRssi(-100, txDbm: 22, txAntennaDbi: 7, rxAntennaDbi: 1),
            Tri.adjustedRssi(-100, txDbm: 22, txAntennaDbi: 1, rxAntennaDbi: 7),
            precision: 6
        ))
    }

    @Test("Hardware presets are sensible")
    func hardwarePresetsAreSensible() {
        #expect(Tri.txPresetDbm("RAK4631") == 22)
        #expect(Tri.txPresetDbm("RAK_WISMESH_TAP") == 27)
        #expect(Tri.txPresetDbm("HELTEC_V3") == 21)
        #expect(Tri.txPresetDbm("TBEAM") == 22)
        #expect(Tri.txPresetDbm(nil) == 20)
        #expect(Tri.txPresetDbm("SOME_FUTURE_BOARD") == 20)
    }

    @Test("dBm to watts conversion")
    func dbmToWatts() {
        #expect(equal(Tri.dbmToWatts(27), 0.5, precision: 2))
        #expect(equal(Tri.dbmToWatts(30), 1.0, precision: 2))
    }

    // MARK: - Position precision

    @Test("Precision bits convert to sensible km radii")
    func precisionBitsConvertToKm() {
        #expect(equal(Tri.precisionBitsToKm(32), 0, precision: 6))
        #expect(equal(Tri.precisionBitsToKm(0), 0, precision: 6))
        #expect((0.3...0.45).contains(Tri.precisionBitsToKm(16)))
        #expect((2.5...3.3).contains(Tri.precisionBitsToKm(13)))
        #expect(Tri.precisionBitsToKm(11) > Tri.precisionBitsToKm(13))
    }

    @Test("The anchor position-error dead zone absorbs truncated positions")
    func deadZoneAbsorbsTruncatedPositions() throws {
        let displaced = (lat: 50.80 + 0.027, lon: 9.55)
        func build(_ posErr: Double) -> [Anchor] {
            let exact = surroundingAnchors
            return [
                Anchor(lat: exact[0].lat, lon: exact[0].lon,
                       distKm: distKm(exact[0].lat, exact[0].lon, alsfeldTruth.lat, alsfeldTruth.lon)),
                Anchor(lat: exact[1].lat, lon: exact[1].lon,
                       distKm: distKm(exact[1].lat, exact[1].lon, alsfeldTruth.lat, alsfeldTruth.lon)),
                Anchor(lat: displaced.lat, lon: displaced.lon,
                       distKm: distKm(exact[2].lat, exact[2].lon, alsfeldTruth.lat, alsfeldTruth.lon),
                       posErrKm: posErr),
            ]
        }
        let withError = try #require(Tri.estimate(build(4)))
        let withoutError = try #require(Tri.estimate(build(0)))
        let errorWith = distKm(withError.lat, withError.lon, alsfeldTruth.lat, alsfeldTruth.lon)
        let errorWithout = distKm(withoutError.lat, withoutError.lon, alsfeldTruth.lat, alsfeldTruth.lon)
        #expect(errorWith <= errorWithout + 0.3,
                "dead zone should not worsen the estimate (\(errorWith) vs \(errorWithout) km)")
        #expect(errorWith < 2.5, "estimate off by \(errorWith) km despite dead zone")
    }

    @Test("A reported-position prior pulls the estimate toward its cell")
    func reportedPositionPriorPullsEstimate() throws {
        let reported = alsfeldTruth
        let rfOnly = [
            Anchor(lat: 50.90, lon: 9.10, distKm: 3.0),
            Anchor(lat: 50.88, lon: 9.40, distKm: 3.0),
        ]
        let withPrior = rfOnly + [
            Anchor(lat: reported.lat, lon: reported.lon, distKm: 0, posErrKm: 3.0, weightScale: 5),
        ]
        let without = try #require(Tri.estimate(rfOnly))
        let with = try #require(Tri.estimate(withPrior))
        let dWithout = distKm(without.lat, without.lon, reported.lat, reported.lon)
        let dWith = distKm(with.lat, with.lon, reported.lat, reported.lon)
        #expect(dWith < dWithout * 0.55, "prior should at least halve the offset (\(dWith) vs \(dWithout) km)")
        #expect(dWith < 8, "estimate \(dWith) km from the reported cell")
    }

    // MARK: - Self-calibration

    private func synth(_ p1: Double, _ n: Double, _ distances: [Double]) -> [(distKm: Double, rssi: Double)] {
        distances.map { ($0, p1 - 10 * n * log10($0)) }
    }

    @Test("Calibration recovers known model parameters")
    func calibrationRecoversParameters() {
        let calibration = Tri.fitCalibration(synth(-95, 3.0, [0.5, 1, 2, 3, 5, 8, 12, 20, 30]))
        #expect(calibration.isFitted)
        #expect(equal(calibration.p1Km, -95, precision: 1))
        #expect(equal(calibration.exponent, 3.0, precision: 2))
    }

    @Test("Calibration flags noise without correlation as low quality")
    func calibrationFlagsNoise() {
        var random = DotNetRandom(seed: 42)
        let samples = (0..<24).map { _ -> (distKm: Double, rssi: Double) in
            let distance = 0.5 + random.nextDouble() * 25
            let rssi = -115 + random.nextDouble() * 30
            return (distance, rssi)
        }
        let calibration = Tri.fitCalibration(samples)
        #expect(!calibration.isFitted || calibration.r2 < 0.2, "garbage fit not flagged (R²=\(calibration.r2))")
    }

    @Test("The .NET Random port reproduces the seeded sequence")
    func dotNetRandomPort() {
        var random = DotNetRandom(seed: 42)
        #expect(abs(random.nextDouble() - 0.668106465911542) < 1e-12)
    }

    @Test("A clean fit reports a high R²")
    func cleanFitReportsHighR2() {
        let calibration = Tri.fitCalibration(synth(-95, 3.0, [0.5, 1, 2, 3, 5, 8, 12, 20, 30]))
        #expect(calibration.isFitted)
        #expect(calibration.r2 > 0.95)
    }

    @Test("Calibration falls back on thin or degenerate data")
    func calibrationFallsBack() {
        #expect(!Tri.fitCalibration(synth(-95, 3.0, [1, 2, 5])).isFitted)
        #expect(!Tri.fitCalibration(synth(-95, 3.0, [5, 5.1, 5.2, 4.9, 5.05, 5.15, 4.95, 5.0])).isFitted)
        #expect(!Tri.fitCalibration(synth(-95, -2.0, [0.5, 1, 2, 3, 5, 8, 12, 20])).isFitted)
    }

    @Test("Calibration clamps extreme fits to sane RF ranges")
    func calibrationClampsExtremeFits() {
        let calibration = Tri.fitCalibration(synth(-80, 9.0, [0.5, 1, 2, 3, 5, 8, 12, 20]))
        #expect(calibration.isFitted)
        #expect((1.8...4.5).contains(calibration.exponent))
        #expect((-110...(-70)).contains(calibration.p1Km))
    }

    @Test("A fitted calibration changes distance estimates")
    func fittedCalibrationChangesDistances() {
        let calibration = Tri.fitCalibration(synth(-100, 3.0, [0.5, 1, 2, 3, 5, 8, 12, 20, 30]))
        #expect(equal(Tri.signalDistanceKm(-100, calibration), 1.0, precision: 2))
        #expect(Tri.signalDistanceKm(-100) > 2.0)
    }
}
