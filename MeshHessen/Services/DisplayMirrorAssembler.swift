import Foundation

/// A rendered device display: row-major, 8-bit RGBA (alpha always 255).
struct DisplayMirrorImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: Data
}

/// Display-mirroring reassembly (firmware 2.8). `FromRadio.display_frame` arrives as
/// ordered, contiguous chunks of one frame; a chunk with offset 0 starts a new frame
/// and an out-of-sequence chunk drops the partial one. Two formats:
/// - MONO_VLSB: full frames; `total_size = width * ceil(height / 8)`, pixel (x, y) is
///   bit `y % 8` of byte `(y / 8) * width + x`. Optionally colorized by a
///   `DisplayPalette` (RGB565 colors, region table where the highest index wins).
/// - RGB565: dirty rectangles composited into a persistent little-endian canvas;
///   the rectangle geometry is latched from the offset-0 chunk.
///
/// Ported from the Windows client's `DisplayMirrorAssembler.cs`. Every
/// device-controlled field is validated before any allocation.
struct DisplayMirrorAssembler {
    static let pixelsPerPage = 8
    /// Generous cap: 800x480 mono = 48 KB; RGB565 rects stay below this.
    static let maxFrameBytes = 512 * 1024
    static let maxPaletteRegions = 64

    struct Frame: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameID: UInt32
        let paletteSignature: UInt32
        let pixels: [UInt8]
        let isRGB565: Bool
    }

    struct PaletteRegion: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let onColor: Int
        let offColor: Int
    }

    struct Palette: Equatable, Sendable {
        let signature: UInt32
        let defaultOn: Int
        let defaultOff: Int
        let regions: [PaletteRegion]
    }

    private struct RectArea {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let panelWidth: Int
        let panelHeight: Int
    }

    // MARK: - Mono full-frame state
    private var buffer: [UInt8]?
    private var frameID: UInt32 = 0
    private var received = 0
    private var frameWidth = 0
    private var frameHeight = 0

    // MARK: - RGB565 rect-compositor state
    private var canvas: [UInt8]?
    private var canvasWidth = 0
    private var canvasHeight = 0
    private var rectBuffer: [UInt8]?
    private var rectFrameID: UInt32 = 0
    private var rectReceived = 0
    private var rectArea: RectArea?

    // MARK: - Palette state
    private var paletteRegions: [PaletteRegion] = []
    private var paletteSignature: UInt32 = 0
    private var paletteTotal = 0
    private var paletteReceived = -1
    private var paletteDefaultOn = 0
    private var paletteDefaultOff = 0

    // MARK: - Rendering state
    /// Last completed palette; applied to mono frames whose signature matches.
    private(set) var palette: Palette?
    /// Last completed mono frame, re-rendered when its palette arrives later.
    private var lastMonoFrame: Frame?

    init() {}

    // MARK: - High-level API

    /// Feeds one frame chunk; returns the rendered image when a frame completes.
    mutating func ingest(frame chunk: Meshtastic_DisplayFrame) -> DisplayMirrorImage? {
        guard let frame = handleFrameChunk(chunk) else { return nil }
        if !frame.isRGB565 { lastMonoFrame = frame }
        return Self.image(for: frame, palette: palette)
    }

    /// Feeds one palette chunk. When the palette completes and colorizes the last
    /// mono frame, that frame is re-rendered and returned.
    @discardableResult
    mutating func ingest(palette chunk: Meshtastic_DisplayPalette) -> DisplayMirrorImage? {
        guard let complete = handlePaletteChunk(chunk) else { return nil }
        palette = complete
        guard let frame = lastMonoFrame, frame.paletteSignature != 0,
              frame.paletteSignature == complete.signature else { return nil }
        return Self.image(for: frame, palette: complete)
    }

    static func image(for frame: Frame, palette: Palette?) -> DisplayMirrorImage {
        DisplayMirrorImage(width: frame.width, height: frame.height, rgba: renderRGBA(frame, palette: palette))
    }

    // MARK: - Chunk handling

    /// Feeds one frame chunk; returns the completed frame or nil.
    mutating func handleFrameChunk(_ chunk: Meshtastic_DisplayFrame) -> Frame? {
        chunk.format == .rgb565 ? handleRectChunk(chunk) : handleMonoChunk(chunk)
    }

    private mutating func handleMonoChunk(_ chunk: Meshtastic_DisplayFrame) -> Frame? {
        let data = [UInt8](chunk.data)
        let width = Int(chunk.width)
        let height = Int(chunk.height)
        let total = Int(chunk.totalSize)
        let offset = Int(chunk.offset)
        let expected = width * ((height + Self.pixelsPerPage - 1) / Self.pixelsPerPage)
        let acceptable = chunk.format == .monoVlsb
            && width > 0 && height > 0
            && expected == total && total > 0 && total <= Self.maxFrameBytes
            && offset + data.count <= total
        guard acceptable else {
            buffer = nil
            return nil
        }

        if offset == 0 {
            buffer = [UInt8](repeating: 0, count: total)
            frameID = chunk.frameID
            received = 0
            // Geometry is authoritative on the first chunk; a later chunk may not transpose it.
            frameWidth = width
            frameHeight = height
        }

        guard var buf = buffer, chunk.frameID == frameID, offset == received,
              buf.count == total, width == frameWidth, height == frameHeight else {
            buffer = nil
            return nil
        }

        buffer = nil // avoid a copy-on-write of the buffer while mutating the local
        buf.replaceSubrange(offset..<(offset + data.count), with: data)
        received += data.count
        guard received >= buf.count else {
            buffer = buf
            return nil
        }

        return Frame(
            width: frameWidth,
            height: frameHeight,
            frameID: frameID,
            paletteSignature: chunk.paletteSignature,
            pixels: buf,
            isRGB565: false
        )
    }

    private mutating func handleRectChunk(_ chunk: Meshtastic_DisplayFrame) -> Frame? {
        let data = [UInt8](chunk.data)
        let width = Int(chunk.width)
        let height = Int(chunk.height)
        let rectX = Int(chunk.rectX)
        let rectY = Int(chunk.rectY)
        let rectW = chunk.rectWidth > 0 ? Int(chunk.rectWidth) : width
        let rectH = chunk.rectHeight > 0 ? Int(chunk.rectHeight) : height
        let total = Int(chunk.totalSize)
        let offset = Int(chunk.offset)

        // Subtraction form: rect_x + rect_width could overflow for hostile values.
        let withinPanel = width > 0 && height > 0
            && rectX <= width && rectW <= width - rectX
            && rectY <= height && rectH <= height - rectY
        let expected = withinPanel ? rectW * rectH * 2 : -1
        let sized = expected == total && total > 0 && total <= Self.maxFrameBytes

        var inSequence = offset == 0
        if !inSequence, let latched = rectArea, rectBuffer?.count == total {
            inSequence = chunk.frameID == rectFrameID && offset == rectReceived
                && width == latched.panelWidth && height == latched.panelHeight
        }

        guard sized, inSequence, offset + data.count <= total else {
            rectBuffer = nil
            return nil
        }

        if offset == 0 {
            rectBuffer = [UInt8](repeating: 0, count: total)
            rectFrameID = chunk.frameID
            rectReceived = 0
            rectArea = RectArea(x: rectX, y: rectY, width: rectW, height: rectH,
                                panelWidth: width, panelHeight: height)
        }

        guard var rect = rectBuffer, let area = rectArea else { return nil }
        rectBuffer = nil
        rect.replaceSubrange(offset..<(offset + data.count), with: data)
        rectReceived += data.count
        guard rectReceived >= rect.count else {
            rectBuffer = rect
            return nil
        }

        // Rect complete: composite into the persistent canvas (recreated on panel change).
        var target: [UInt8]
        if let existing = canvas, canvasWidth == area.panelWidth, canvasHeight == area.panelHeight {
            target = existing
        } else {
            target = [UInt8](repeating: 0, count: area.panelWidth * area.panelHeight * 2)
            canvasWidth = area.panelWidth
            canvasHeight = area.panelHeight
        }
        canvas = nil
        let rowBytes = area.width * 2
        for row in 0..<area.height {
            let source = row * rowBytes
            let destination = ((area.y + row) * canvasWidth + area.x) * 2
            target.replaceSubrange(destination..<(destination + rowBytes),
                                   with: rect[source..<(source + rowBytes)])
        }
        canvas = target

        return Frame(
            width: canvasWidth,
            height: canvasHeight,
            frameID: rectFrameID,
            paletteSignature: 0,
            pixels: target,
            isRGB565: true
        )
    }

    /// Feeds one palette chunk; returns the completed palette or nil.
    mutating func handlePaletteChunk(_ chunk: Meshtastic_DisplayPalette) -> Palette? {
        if chunk.regionOffset == 0 && chunk.regionTotal <= UInt32(Self.maxPaletteRegions) {
            paletteRegions.removeAll()
            paletteSignature = chunk.signature
            paletteTotal = Int(chunk.regionTotal)
            paletteReceived = 0
            // Defaults are authoritative on the first chunk; later chunks may omit them.
            paletteDefaultOn = Int(chunk.defaultOnColor)
            paletteDefaultOff = Int(chunk.defaultOffColor)
        }

        let withinTotal = Int(chunk.regionTotal) == paletteTotal && paletteReceived >= 0
            && paletteReceived + chunk.regions.count <= paletteTotal
        let inSequence = chunk.signature == paletteSignature && Int(chunk.regionOffset) == paletteReceived
        guard withinTotal, inSequence else {
            paletteRegions.removeAll()
            paletteReceived = -1 // poisoned until the next offset-0 chunk restarts
            return nil
        }

        for region in chunk.regions {
            paletteRegions.append(PaletteRegion(
                x: Int(region.x), y: Int(region.y),
                width: Int(region.width), height: Int(region.height),
                onColor: Int(region.onColor), offColor: Int(region.offColor)
            ))
        }
        paletteReceived += chunk.regions.count

        guard paletteReceived == paletteTotal else { return nil }
        paletteReceived = -1 // complete; a surplus chunk must not extend it
        return Palette(signature: paletteSignature, defaultOn: paletteDefaultOn,
                       defaultOff: paletteDefaultOff, regions: paletteRegions)
    }

    mutating func reset() {
        self = DisplayMirrorAssembler()
    }

    // MARK: - Rendering

    /// Expands RGB565 to 8-bit channels by bit replication (canonical expansion).
    static func rgb565(_ value: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r5 = (value >> 11) & 0x1F
        let g6 = (value >> 5) & 0x3F
        let b5 = value & 0x1F
        return (UInt8((r5 << 3) | (r5 >> 2)), UInt8((g6 << 2) | (g6 >> 4)), UInt8((b5 << 3) | (b5 >> 2)))
    }

    /// Renders a completed frame to row-major RGBA bytes. The palette applies only
    /// when the frame references it by signature.
    static func renderRGBA(_ frame: Frame, palette: Palette?) -> Data {
        let pixelCount = frame.width * frame.height
        var out = [UInt8](repeating: 255, count: pixelCount * 4)

        if frame.isRGB565 {
            for i in 0..<pixelCount {
                let value = Int(frame.pixels[i * 2]) | (Int(frame.pixels[i * 2 + 1]) << 8) // little-endian
                let color = rgb565(value)
                out[i * 4] = color.r
                out[i * 4 + 1] = color.g
                out[i * 4 + 2] = color.b
            }
            return Data(out)
        }

        let active: Palette? = {
            guard let palette, frame.paletteSignature != 0,
                  palette.signature == frame.paletteSignature else { return nil }
            return palette
        }()
        let on = active.map { rgb565($0.defaultOn) } ?? (255, 255, 255)
        let off = active.map { rgb565($0.defaultOff) } ?? (0, 0, 0)

        for y in 0..<frame.height {
            let page = (y / pixelsPerPage) * frame.width
            let bit = UInt8(1 << (y % pixelsPerPage))
            for x in 0..<frame.width {
                let isSet = (frame.pixels[page + x] & bit) != 0
                let color: (r: UInt8, g: UInt8, b: UInt8)
                if let region = findRegion(active, x: x, y: y) {
                    color = rgb565(isSet ? region.onColor : region.offColor)
                } else {
                    color = isSet ? on : off
                }
                let index = (y * frame.width + x) * 4
                out[index] = color.r
                out[index + 1] = color.g
                out[index + 2] = color.b
            }
        }
        return Data(out)
    }

    /// Highest region index wins: the firmware's precedence.
    private static func findRegion(_ palette: Palette?, x: Int, y: Int) -> PaletteRegion? {
        guard let palette else { return nil }
        return palette.regions.last { region in
            x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
        }
    }
}
