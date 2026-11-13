import Foundation

/// Inverse-distance-weighted interpolation of point sensors into a value grid. Each cell gets
/// the distance-weighted average of the sensors within `influenceKm`, plus a coverage alpha
/// that fades to 0 at the influence radius so areas far from any sensor stay blank instead of
/// extrapolating. Port of the Windows `EnvironmentField`.
enum EnvironmentField {
    struct Sensor: Equatable, Sendable {
        let longitude: Double
        let latitude: Double
        let value: Double
        let confidence: Double
    }

    struct Grid: Equatable, Sendable {
        var lon0: Double
        var lat0: Double
        var dLon: Double
        var dLat: Double
        var nx: Int
        var ny: Int
        /// Row-major (`j * nx + i`), row 0 = south; NaN = no coverage.
        var values: [Double]
        /// Coverage 0…1, indexed like `values`.
        var alpha: [Double]

        /// Centre of cell (i, j).
        func cellCenter(i: Int, j: Int) -> (longitude: Double, latitude: Double) {
            (lon0 + (Double(i) + 0.5) * dLon, lat0 + (Double(j) + 0.5) * dLat)
        }
    }

    static let kmPerDegree = 111.0

    static func build(_ sensors: [Sensor], influenceKm: Double, maxCells: Int = 2_800) -> Grid? {
        guard !sensors.isEmpty, influenceKm > 0 else { return nil }

        var minLon = Double.greatestFiniteMagnitude, minLat = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        for sensor in sensors {
            minLon = min(minLon, sensor.longitude); maxLon = max(maxLon, sensor.longitude)
            minLat = min(minLat, sensor.latitude); maxLat = max(maxLat, sensor.latitude)
        }

        let midLat = (minLat + maxLat) / 2
        let cosLat = max(0.2, cos(midLat * .pi / 180))
        let marginLat = influenceKm / kmPerDegree
        let marginLon = influenceKm / (kmPerDegree * cosLat)
        minLon -= marginLon; maxLon += marginLon
        minLat -= marginLat; maxLat += marginLat

        let widthKm = (maxLon - minLon) * kmPerDegree * cosLat
        let heightKm = (maxLat - minLat) * kmPerDegree
        let cellKm = max(influenceKm / 6, 0.5)   // ~6 cells across the influence radius
        var nx = min(80, max(8, Int((widthKm / cellKm).rounded())))
        var ny = min(80, max(8, Int((heightKm / cellKm).rounded())))
        while nx * ny > maxCells {               // cap payload and work
            if nx >= ny { nx = max(8, nx - 2) } else { ny = max(8, ny - 2) }
            if nx == 8 && ny == 8 { break }
        }

        let dLon = (maxLon - minLon) / Double(nx)
        let dLat = (maxLat - minLat) / Double(ny)
        var values = [Double](repeating: .nan, count: nx * ny)
        var alpha = [Double](repeating: 0, count: nx * ny)
        let r2 = influenceKm * influenceKm

        for j in 0..<ny {
            let lat = minLat + (Double(j) + 0.5) * dLat
            let cellCos = max(0.2, cos(lat * .pi / 180))
            for i in 0..<nx {
                let lon = minLon + (Double(i) + 0.5) * dLon
                var weightSum = 0.0, valueSum = 0.0
                var nearest2 = Double.greatestFiniteMagnitude
                for sensor in sensors {
                    let dxKm = (lon - sensor.longitude) * kmPerDegree * cellCos
                    let dyKm = (lat - sensor.latitude) * kmPerDegree
                    let d2 = dxKm * dxKm + dyKm * dyKm
                    if d2 > r2 { continue }
                    let weight = sensor.confidence / (d2 + 1)   // 1/d² with a ~1 km² epsilon
                    weightSum += weight
                    valueSum += weight * sensor.value
                    nearest2 = min(nearest2, d2)
                }
                let index = j * nx + i
                guard weightSum > 0 else { continue }
                values[index] = valueSum / weightSum
                alpha[index] = min(1, max(0, 1 - nearest2.squareRoot() / influenceKm))
            }
        }

        return Grid(lon0: minLon, lat0: minLat, dLon: dLon, dLat: dLat, nx: nx, ny: ny, values: values, alpha: alpha)
    }
}
