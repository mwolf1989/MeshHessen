import Foundation

/// A contour line segment in longitude/latitude.
struct EnvironmentSegment: Equatable, Sendable {
    let lon1: Double
    let lat1: Double
    let lon2: Double
    let lat2: Double

    var asArray: [Double] { [lon1, lat1, lon2, lat2] }
}

/// Marching-squares contour extraction over an `EnvironmentField.Grid`: for each level (band
/// boundary) the iso-value line segments in lon/lat. Port of the Windows `EnvironmentContours`.
enum EnvironmentContours {
    /// Edge → the two corner indices it connects (corners: 0 = SW, 1 = SE, 2 = NE, 3 = NW).
    private static let edgeCorners: [(Int, Int)] = [(0, 1), (1, 2), (2, 3), (3, 0)]

    /// Per marching-squares case (corner ≥ level bitmask SW = 1, SE = 2, NE = 4, NW = 8): edge pairs.
    private static let caseEdges: [[Int]] = [
        [],              // 0
        [3, 0],          // 1  SW
        [0, 1],          // 2  SE
        [3, 1],          // 3  SW SE
        [1, 2],          // 4  NE
        [3, 0, 1, 2],    // 5  SW NE (saddle)
        [0, 2],          // 6  SE NE
        [3, 2],          // 7  SW SE NE
        [2, 3],          // 8  NW
        [2, 0],          // 9  SW NW
        [0, 1, 2, 3],    // 10 SE NW (saddle)
        [2, 1],          // 11 SW SE NW
        [1, 3],          // 12 NE NW
        [1, 0],          // 13 SW NE NW
        [0, 3],          // 14 SE NE NW
        [],              // 15
    ]

    struct LabelAnchor: Equatable, Sendable {
        let longitude: Double
        let latitude: Double
        /// Grid index of a corner on the warmer side (value ≥ level), or -1.
        let warmerCell: Int
    }

    static func build(_ grid: EnvironmentField.Grid, levels: [Double]) -> [EnvironmentSegment] {
        buildCore(grid, levels: levels).map(\.segment)
    }

    /// Label anchors on the drawn iso-lines (segment midpoints) with a warmer-side cell index,
    /// so the caller can look up that zone's average value.
    static func lineLabelAnchors(_ grid: EnvironmentField.Grid, levels: [Double]) -> [LabelAnchor] {
        buildCore(grid, levels: levels).map { item in
            LabelAnchor(
                longitude: (item.segment.lon1 + item.segment.lon2) / 2,
                latitude: (item.segment.lat1 + item.segment.lat2) / 2,
                warmerCell: item.warmerCell
            )
        }
    }

    private static func buildCore(
        _ grid: EnvironmentField.Grid,
        levels: [Double]
    ) -> [(segment: EnvironmentSegment, warmerCell: Int)] {
        guard grid.nx >= 2, grid.ny >= 2, !levels.isEmpty else { return [] }
        var result: [(segment: EnvironmentSegment, warmerCell: Int)] = []
        let nx = grid.nx

        for j in 0..<(grid.ny - 1) {
            for i in 0..<(nx - 1) {
                let cells = [j * nx + i, j * nx + i + 1, (j + 1) * nx + i + 1, (j + 1) * nx + i]
                let cv = cells.map { grid.values[$0] }   // SW, SE, NE, NW
                if cv.contains(where: \.isNaN) { continue }

                let lonW = grid.lon0 + (Double(i) + 0.5) * grid.dLon
                let lonE = lonW + grid.dLon
                let latS = grid.lat0 + (Double(j) + 0.5) * grid.dLat
                let latN = latS + grid.dLat
                let cx = [lonW, lonE, lonE, lonW]
                let cy = [latS, latS, latN, latN]

                for level in levels {
                    var mask = 0
                    for corner in 0..<4 where cv[corner] >= level { mask |= 1 << corner }
                    let edges = caseEdges[mask]
                    if edges.isEmpty { continue }

                    let warmer = (0..<4).first { cv[$0] >= level }.map { cells[$0] } ?? -1
                    var index = 0
                    while index + 1 < edges.count {
                        let p1 = edgeCross(edges[index], cx: cx, cy: cy, cv: cv, level: level)
                        let p2 = edgeCross(edges[index + 1], cx: cx, cy: cy, cv: cv, level: level)
                        result.append((
                            EnvironmentSegment(lon1: p1.lon, lat1: p1.lat, lon2: p2.lon, lat2: p2.lat),
                            warmer
                        ))
                        index += 2
                    }
                }
            }
        }
        return result
    }

    private static func edgeCross(
        _ edge: Int,
        cx: [Double],
        cy: [Double],
        cv: [Double],
        level: Double
    ) -> (lon: Double, lat: Double) {
        let (a, b) = edgeCorners[edge]
        let denominator = cv[b] - cv[a]
        var t = abs(denominator) < 1e-9 ? 0.5 : (level - cv[a]) / denominator
        t = min(1, max(0, t))
        return (cx[a] + t * (cx[b] - cx[a]), cy[a] + t * (cy[b] - cy[a]))
    }
}

/// Groups the grid into contiguous same-band zones (the areas between iso-lines) and returns
/// each cell's zone average. Port of the Windows `EnvironmentZones`.
enum EnvironmentZones {
    /// Per-cell average value of its 4-connected same-band zone; NaN where uncovered.
    static func zoneAverages(_ grid: EnvironmentField.Grid, min: Double, step: Double, bandCount: Int) -> [Double] {
        let nx = grid.nx, ny = grid.ny, count = nx * ny
        var averages = [Double](repeating: .nan, count: count)
        guard nx >= 1, ny >= 1, step > 0, bandCount > 0 else { return averages }

        var band = [Int](repeating: -1, count: count)
        for index in 0..<count {
            let value = grid.values[index]
            guard !value.isNaN, grid.alpha[index] > 0.1 else { continue }
            band[index] = Swift.min(bandCount - 1, Swift.max(0, Int(((value - min) / step).rounded(.down))))
        }

        var visited = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for start in 0..<count where !visited[start] && band[start] >= 0 {
            let zoneBand = band[start]
            var cells: [Int] = []
            var sum = 0.0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let index = stack.popLast() {
                cells.append(index)
                sum += grid.values[index]
                let ci = index % nx, cj = index / nx
                for (ni, nj) in [(ci - 1, cj), (ci + 1, cj), (ci, cj - 1), (ci, cj + 1)] {
                    guard ni >= 0, nj >= 0, ni < nx, nj < ny else { continue }
                    let neighbour = nj * nx + ni
                    if !visited[neighbour] && band[neighbour] == zoneBand {
                        visited[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            let average = sum / Double(cells.count)
            for cell in cells { averages[cell] = average }
        }
        return averages
    }
}
