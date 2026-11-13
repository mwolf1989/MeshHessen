import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders an `EnvironmentField.Grid` into a bilinearly upsampled RGBA image coloured by the
/// metric's ramp with the coverage alpha, so both map renderers show soft, blended edges
/// instead of blocky cells. Port of the Windows `EnvironmentRaster`.
enum EnvironmentRaster {
    struct Image: Equatable, Sendable {
        let width: Int
        let height: Int
        /// Straight (non-premultiplied) RGBA, row 0 = north.
        let pixels: [UInt8]
        /// Extent of the image (grid-centre span: pixels map centre to centre).
        let minLongitude: Double
        let minLatitude: Double
        let maxLongitude: Double
        let maxLatitude: Double

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
    }

    /// - Parameters:
    ///   - maxOpacity: peak fill opacity (0…1) so the base map stays readable.
    ///   - bandCount: > 0 quantises the colour into that many bands, so it changes exactly at
    ///     the contour lines. 0 = smooth gradient.
    static func render(
        _ grid: EnvironmentField.Grid,
        min: Double,
        max: Double,
        maxOpacity: Double,
        bandCount: Int = 0,
        cellPixels: Int = 10,
        maxDimension: Int = 640,
        rgbAt: (Double) -> EnvironmentRGB = EnvironmentMetricInfo.rgb(at:)
    ) -> Image? {
        guard grid.nx >= 2, grid.ny >= 2 else { return nil }

        let width = Swift.min(maxDimension, Swift.max(128, grid.nx * cellPixels))
        let height = Swift.min(maxDimension, Swift.max(128, grid.ny * cellPixels))
        let span = max - min

        // 256-entry colour table; when banded, snap to the band centre (flat colour per band).
        let lookup: [EnvironmentRGB] = (0..<256).map { index in
            var t = Double(index) / 255
            if bandCount > 0 {
                let band = Swift.min(bandCount - 1, Swift.max(0, Int(t * Double(bandCount))))
                t = (Double(band) + 0.5) / Double(bandCount)
            }
            return rgbAt(t)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            // Image row 0 = north (max latitude); grid row 0 = south → flip.
            let gy = (1 - Double(py) / Double(height - 1)) * Double(grid.ny - 1)
            let j0 = Int(gy.rounded(.down))
            let j1 = Swift.min(j0 + 1, grid.ny - 1)
            let fy = gy - Double(j0)
            for px in 0..<width {
                let gx = Double(px) / Double(width - 1) * Double(grid.nx - 1)
                let i0 = Int(gx.rounded(.down))
                let i1 = Swift.min(i0 + 1, grid.nx - 1)
                let fx = gx - Double(i0)

                // Bilinear over the four grid centres, ignoring NaN (no coverage).
                var valueSum = 0.0, weightSum = 0.0, alphaSum = 0.0
                for (i, j, weight) in [
                    (i0, j0, (1 - fx) * (1 - fy)), (i1, j0, fx * (1 - fy)),
                    (i0, j1, (1 - fx) * fy), (i1, j1, fx * fy),
                ] {
                    let index = j * grid.nx + i
                    alphaSum += weight * grid.alpha[index]
                    let value = grid.values[index]
                    if !value.isNaN {
                        valueSum += weight * value
                        weightSum += weight
                    }
                }

                guard weightSum > 0, alphaSum > 0.001 else { continue }   // transparent
                let value = valueSum / weightSum
                let t = span > 0 ? Swift.min(1, Swift.max(0, (value - min) / span)) : 0
                let colour = lookup[Int(t * 255)]
                let offset = (py * width + px) * 4
                pixels[offset] = colour.r
                pixels[offset + 1] = colour.g
                pixels[offset + 2] = colour.b
                pixels[offset + 3] = UInt8(Swift.min(255, Swift.max(0, alphaSum * maxOpacity * 255)))
            }
        }

        return Image(
            width: width,
            height: height,
            pixels: pixels,
            minLongitude: grid.lon0 + 0.5 * grid.dLon,
            minLatitude: grid.lat0 + 0.5 * grid.dLat,
            maxLongitude: grid.lon0 + (Double(grid.nx) - 0.5) * grid.dLon,
            maxLatitude: grid.lat0 + (Double(grid.ny) - 0.5) * grid.dLat
        )
    }

    /// The image as a `CGImage` (straight alpha).
    static func cgImage(_ image: Image) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// PNG encoding of the image (for the vector map's image source).
    static func pngData(_ image: Image) -> Data? {
        guard let cgImage = cgImage(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
