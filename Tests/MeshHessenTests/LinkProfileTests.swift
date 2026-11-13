import Foundation
import Testing

@testable import MeshHessen

/// Link elevation profile, Fresnel and knife-edge helpers (ports of the terrain tests in
/// `TriangulationTests.cs` plus profile/verdict checks).
@Suite("Link profile")
struct LinkProfileTests {
    private static let start = LinkProfilePoint(latitude: 50.0, longitude: 8.0)
    /// ≈ 10 km east of `start`.
    private static let end = LinkProfilePoint(latitude: 50.0, longitude: 8.14)

    private static let flat: ElevationSampler = { _, _ in 100 }
    /// 300 m ridge mid-path between two 100 m endpoints.
    private static let ridge: ElevationSampler = { _, longitude in
        longitude > 8.06 && longitude < 8.08 ? 300 : 100
    }
    private static let noData: ElevationSampler = { _, _ in nil }

    // MARK: - Ported from TriangulationTests.cs

    @Test("Knife-edge loss is zero when clear and grows with v")
    func knifeEdgeLoss() {
        #expect(abs(LinkProfile.knifeEdgeLossDb(-1)) < 1e-6)
        #expect(abs(LinkProfile.knifeEdgeLossDb(-0.79)) < 1e-6)
        #expect(abs(LinkProfile.knifeEdgeLossDb(0) - 6.0) < 0.1)   // grazing LOS ≈ 6 dB
        #expect(LinkProfile.knifeEdgeLossDb(1) > LinkProfile.knifeEdgeLossDb(0))
        #expect(LinkProfile.knifeEdgeLossDb(3) > LinkProfile.knifeEdgeLossDb(1))
    }

    @Test("Flat terrain has no excess loss, but its absolute Fresnel zone is dragged")
    func flatTerrainExcessLoss() {
        let excess = LinkProfile.pathExcessLossDb(
            elevation: Self.flat, from: Self.start, antennaHeight: 2.5, to: Self.end, antennaHeight: 2.5
        )
        #expect(abs(excess) < 1e-6)
        let v = LinkProfile.pathFresnelV(
            elevation: Self.flat, from: Self.start, antennaHeight: 2.5, to: Self.end, antennaHeight: 2.5
        )
        #expect(v > -0.78)
    }

    @Test("A ridge between the endpoints yields excess loss")
    func ridgeExcessLoss() {
        let excess = LinkProfile.pathExcessLossDb(
            elevation: Self.ridge, from: Self.start, antennaHeight: 2.5, to: Self.end, antennaHeight: 2.5
        )
        #expect(excess > 6, "expected clearly positive excess loss, got \(excess) dB")
        let beyondRidge = LinkProfile.pathExcessLossDb(
            elevation: Self.ridge,
            from: LinkProfilePoint(latitude: 50.0, longitude: 8.09), antennaHeight: 2.5,
            to: Self.end, antennaHeight: 2.5
        )
        #expect(abs(beyondRidge) < 1e-6)
    }

    @Test("No elevation data means no penalty")
    func noDataNoPenalty() {
        let excess = LinkProfile.pathExcessLossDb(
            elevation: Self.noData, from: Self.start, antennaHeight: 2.5, to: Self.end, antennaHeight: 2.5
        )
        #expect(abs(excess) < 1e-6)
        let v = LinkProfile.pathFresnelV(
            elevation: Self.noData, from: Self.start, antennaHeight: 2.5, to: Self.end, antennaHeight: 2.5
        )
        #expect(v == -10)
    }

    // MARK: - Profile

    @Test("Flat 10 km: worst margin at mid-path is 2.5 m − bulge − 0.6·f1")
    func flatProfileMargin() throws {
        let result = LinkProfile.compute(from: Self.start, to: Self.end, elevation: Self.flat)
        let distance = result.distance
        #expect(abs(distance - 10_000) < 50)

        let half = distance / 2
        let bulge = half * half / (2 * LinkProfile.effectiveEarthRadius)
        let f1 = sqrt(LinkProfile.wavelength() * half * half / distance)
        let expected = 2.5 - bulge - 0.6 * f1

        let margin = try #require(result.worstMargin)
        #expect(abs(margin - expected) < 0.05)
        #expect(abs(try #require(result.worstMarginDistance) - half) < distance / 100)
        #expect(result.samples.count == LinkProfile.drawingSamples + 1)
        #expect(result.startElevation == 100)

        // The line of sight itself is free (2.5 m masts > 1.5 m bulge), but the 60 % Fresnel
        // zone is dragged by the ground, so the Windows formula reports ≈ 6 dB: marginal.
        #expect(result.fresnelV < 0)
        #expect(result.knifeEdgeLoss > 0)
        #expect(result.verdict == .marginal)
    }

    @Test("Flat 10 km with 30 m masts is clear")
    func flatProfileHighMastsClear() throws {
        let result = LinkProfile.compute(
            from: Self.start, to: Self.end, antennaHeights: (30, 30), elevation: Self.flat
        )
        #expect(result.verdict == .clear)
        #expect(result.knifeEdgeLoss == 0)
        #expect(try #require(result.worstMargin) > 0)
    }

    @Test("A 300 m ridge mid-path obstructs the link with more than 6 dB loss")
    func ridgeObstructs() throws {
        let result = LinkProfile.compute(from: Self.start, to: Self.end, elevation: Self.ridge)
        #expect(result.verdict == .obstructed)
        #expect(result.knifeEdgeLoss > 6)
        #expect(try #require(result.worstMargin) < -150)
        let at = try #require(result.worstMarginDistance)
        #expect(at > 4_000 && at < 6_000)
    }

    @Test("Unknown heights give verdict unknown")
    func unknownHeights() {
        let missing = LinkProfile.compute(from: Self.start, to: Self.end, elevation: Self.noData)
        #expect(missing.verdict == .unknown)
        #expect(missing.samples.isEmpty)
        #expect(missing.worstMargin == nil)

        let noGrid = LinkProfile.compute(from: Self.start, to: Self.end, grid: nil)
        #expect(noGrid.verdict == .unknown)
        #expect(abs(noGrid.distance - 10_000) < 50)
    }

    @Test("Profile against a terrain grid uses its heights")
    func profileAgainstGrid() throws {
        // Constant 120 m grid covering the whole 10 km path at z10.
        let range = try #require(TerrainTileMath.bestTileRange(covering: TerrainBounds(
            latitude1: Self.start.latitude, longitude1: Self.start.longitude,
            latitude2: Self.end.latitude, longitude2: Self.end.longitude
        ).padded()))
        let width = (range.maxX - range.minX + 1) * 256
        let height = (range.maxY - range.minY + 1) * 256
        let grid = TerrainGrid(
            heights: [Float](repeating: 120, count: width * height),
            width: width,
            height: height,
            originX: Double(range.minX * 256),
            originY: Double(range.minY * 256),
            zoom: range.zoom
        )
        let result = LinkProfile.compute(from: Self.start, to: Self.end, grid: grid)
        #expect(result.verdict == .marginal)
        #expect(result.samples.allSatisfy { abs($0.terrain - 120) < 0.001 })
    }
}
