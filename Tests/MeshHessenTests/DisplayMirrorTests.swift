import Foundation
import Testing

@testable import MeshHessen

/// Display-mirroring reassembly (firmware 2.8): chunked MONO_VLSB frames, RGB565
/// dirty rects, palette chunking and pixel/colour rendering. Ported from the
/// Windows client's `DisplayMirrorTests.cs`.
@Suite("Display Mirror")
struct DisplayMirrorTests {
    private static func monoChunk(
        width: Int, height: Int, frameID: UInt32, offset: Int, data: [UInt8], total: Int,
        paletteSignature: UInt32 = 0
    ) -> Meshtastic_DisplayFrame {
        var chunk = Meshtastic_DisplayFrame()
        chunk.format = .monoVlsb
        chunk.width = UInt32(width)
        chunk.height = UInt32(height)
        chunk.frameID = frameID
        chunk.offset = UInt32(offset)
        chunk.totalSize = UInt32(total)
        chunk.data = Data(data)
        chunk.paletteSignature = paletteSignature
        return chunk
    }

    private static func region(
        x: UInt32 = 0, y: UInt32 = 0, width: UInt32, height: UInt32, on: UInt32 = 0, off: UInt32 = 0
    ) -> Meshtastic_DisplayPalette.ColorRegion {
        var region = Meshtastic_DisplayPalette.ColorRegion()
        region.x = x
        region.y = y
        region.width = width
        region.height = height
        region.onColor = on
        region.offColor = off
        return region
    }

    private static func paletteChunk(
        signature: UInt32, offset: UInt32, total: UInt32,
        defaultOn: UInt32 = 0, defaultOff: UInt32 = 0,
        regions: [Meshtastic_DisplayPalette.ColorRegion]
    ) -> Meshtastic_DisplayPalette {
        var chunk = Meshtastic_DisplayPalette()
        chunk.signature = signature
        chunk.regionOffset = offset
        chunk.regionTotal = total
        chunk.defaultOnColor = defaultOn
        chunk.defaultOffColor = defaultOff
        chunk.regions = regions
        return chunk
    }

    /// RGBA of pixel `index` as `0xRRGGBBAA`.
    private static func pixel(_ rgba: Data, _ index: Int) -> UInt32 {
        let bytes = [UInt8](rgba[(index * 4)..<(index * 4 + 4)])
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static let white: UInt32 = 0xFFFF_FFFF
    private static let black: UInt32 = 0x0000_00FF
    private static let red: UInt32 = 0xFF00_00FF
    private static let green: UInt32 = 0x00FF_00FF

    @Test("A mono frame reassembles from three in-order chunks")
    func monoFrameReassemblesFromThreeChunks() throws {
        var assembler = DisplayMirrorAssembler()
        let width = 128, height = 64, total = width * height / 8 // 1024 bytes
        var full = [UInt8](repeating: 0, count: total)
        full[0] = 0x01          // pixel (0,0)
        full[total - 1] = 0x80  // pixel (127,63)

        let first = assembler.handleFrameChunk(Self.monoChunk(
            width: width, height: height, frameID: 7, offset: 0, data: Array(full[0..<384]), total: total))
        let second = assembler.handleFrameChunk(Self.monoChunk(
            width: width, height: height, frameID: 7, offset: 384, data: Array(full[384..<768]), total: total))
        let third = assembler.handleFrameChunk(Self.monoChunk(
            width: width, height: height, frameID: 7, offset: 768, data: Array(full[768...]), total: total))

        #expect(first == nil)
        #expect(second == nil)
        let frame = try #require(third)
        #expect(frame.width == 128)
        #expect(frame.height == 64)
        #expect(frame.frameID == 7)
        #expect(frame.isRGB565 == false)
        #expect(frame.pixels == full)

        // Default rendering: set = white, unset = black (no palette)
        let rgba = DisplayMirrorAssembler.renderRGBA(frame, palette: nil)
        #expect(Self.pixel(rgba, 0) == Self.white)              // (0,0) set
        #expect(Self.pixel(rgba, 1) == Self.black)              // (1,0) unset
        #expect(Self.pixel(rgba, 63 * 128 + 127) == Self.white) // (127,63) set
    }

    @Test("An out-of-sequence mono chunk drops the partial frame")
    func monoOutOfSequenceChunkDropsPartialFrame() {
        var assembler = DisplayMirrorAssembler()
        let total = 128 * 64 / 8
        let first = assembler.handleFrameChunk(Self.monoChunk(
            width: 128, height: 64, frameID: 7, offset: 0, data: [UInt8](repeating: 0, count: 384), total: total))
        // Wrong offset → dropped; the final chunk alone must not complete anything.
        let gap = assembler.handleFrameChunk(Self.monoChunk(
            width: 128, height: 64, frameID: 7, offset: 512, data: [UInt8](repeating: 0, count: 384), total: total))
        let last = assembler.handleFrameChunk(Self.monoChunk(
            width: 128, height: 64, frameID: 7, offset: 768, data: [UInt8](repeating: 0, count: 256), total: total))
        #expect(first == nil)
        #expect(gap == nil)
        #expect(last == nil)
    }

    @Test("A mono chunk with lying geometry is rejected")
    func monoRejectsLyingGeometry() {
        var assembler = DisplayMirrorAssembler()
        // total_size must equal width * ceil(height / 8)
        let frame = assembler.handleFrameChunk(Self.monoChunk(
            width: 128, height: 64, frameID: 1, offset: 0, data: [UInt8](repeating: 0, count: 100), total: 100))
        #expect(frame == nil)
    }

    @Test("A frame larger than the 512 KB cap is rejected")
    func oversizeFrameIsRejected() {
        var assembler = DisplayMirrorAssembler()
        // 4200 x 1000 mono = 525 000 bytes > 512 KB; geometry is otherwise consistent.
        let width = 4_200, height = 1_000, total = width * height / 8
        let frame = assembler.handleFrameChunk(Self.monoChunk(
            width: width, height: height, frameID: 1, offset: 0, data: [UInt8](repeating: 0, count: total), total: total))
        #expect(frame == nil)
    }

    @Test("An RGB565 rect composites into the persistent canvas")
    func rgb565RectCompositesIntoCanvas() throws {
        var assembler = DisplayMirrorAssembler()
        // 2x1 rect at (1,1) on a 4x2 panel: 2 pixels, little-endian RGB565.
        // 0xF800 = pure red, 0x07E0 = pure green
        var chunk = Meshtastic_DisplayFrame()
        chunk.format = .rgb565
        chunk.width = 4
        chunk.height = 2
        chunk.frameID = 3
        chunk.rectX = 1
        chunk.rectY = 1
        chunk.rectWidth = 2
        chunk.rectHeight = 1
        chunk.offset = 0
        chunk.totalSize = 4
        chunk.data = Data([0x00, 0xF8, 0xE0, 0x07])

        let frameResult = assembler.handleFrameChunk(chunk)
        let frame = try #require(frameResult)
        #expect(frame.width == 4)
        #expect(frame.height == 2)
        #expect(frame.isRGB565)

        let rgba = DisplayMirrorAssembler.renderRGBA(frame, palette: nil)
        #expect(Self.pixel(rgba, 0) == Self.black)         // untouched canvas = black
        #expect(Self.pixel(rgba, 1 * 4 + 1) == Self.red)   // red at (1,1)
        #expect(Self.pixel(rgba, 1 * 4 + 2) == Self.green) // green at (2,1)
    }

    @Test("A palette colorizes matching frames only")
    func paletteColorizesMatchingFramesOnly() throws {
        var paletteAssembler = DisplayMirrorAssembler()
        let completed = paletteAssembler.handlePaletteChunk(Self.paletteChunk(
            signature: 42, offset: 0, total: 1, defaultOn: 0xFFFF, defaultOff: 0x0000,
            regions: [Self.region(width: 1, height: 1, on: 0xF800, off: 0x0000)]
        ))
        let palette = try #require(completed)
        #expect(palette.signature == 42)

        var data = [UInt8](repeating: 0, count: 8)
        data[0] = 0x01 // pixel (0,0) set
        data[1] = 0x01 // pixel (1,0) set

        // Frame references the palette → region red at (0,0), default white at (1,0)
        var frameAssembler = DisplayMirrorAssembler()
        let frameResult = frameAssembler.handleFrameChunk(Self.monoChunk(
            width: 8, height: 8, frameID: 1, offset: 0, data: data, total: 8, paletteSignature: 42))
        let frame = try #require(frameResult)
        let rgba = DisplayMirrorAssembler.renderRGBA(frame, palette: palette)
        #expect(Self.pixel(rgba, 0) == Self.red)
        #expect(Self.pixel(rgba, 1) == Self.white)

        // Signature mismatch → plain monochrome
        var otherAssembler = DisplayMirrorAssembler()
        let otherResult = otherAssembler.handleFrameChunk(Self.monoChunk(
            width: 8, height: 8, frameID: 2, offset: 0, data: data, total: 8, paletteSignature: 7))
        let other = try #require(otherResult)
        let rgbaOther = DisplayMirrorAssembler.renderRGBA(other, palette: palette)
        #expect(Self.pixel(rgbaOther, 0) == Self.white)
    }

    @Test("A bad palette continuation poisons until an offset-0 restart")
    func paletteBadContinuationPoisonsUntilRestart() {
        var assembler = DisplayMirrorAssembler()
        let first = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 9, offset: 0, total: 2, regions: [Self.region(width: 1, height: 1)]))
        // Restarting offset 0 with total 2 restarts and stays incomplete.
        let second = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 9, offset: 0, total: 2, regions: [Self.region(width: 1, height: 1)]))
        // …but an offset-0 restart with total 1 completes cleanly.
        let restart = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 10, offset: 0, total: 1, regions: [Self.region(width: 1, height: 1)]))
        #expect(first == nil)
        #expect(second == nil)
        #expect(restart != nil)
    }

    @Test("A palette chunk at the wrong offset is discarded")
    func paletteWrongOffsetIsDiscarded() {
        var assembler = DisplayMirrorAssembler()
        let first = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 9, offset: 0, total: 2, regions: [Self.region(width: 1, height: 1)]))
        let gap = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 9, offset: 2, total: 2, regions: [Self.region(width: 1, height: 1)]))
        let late = assembler.handlePaletteChunk(Self.paletteChunk(
            signature: 9, offset: 1, total: 2, regions: [Self.region(width: 1, height: 1)]))
        #expect(first == nil)
        #expect(gap == nil)
        #expect(late == nil) // poisoned: the gap dropped the partial palette
    }

    @Test("RGB565 expansion uses bit replication")
    func rgb565ExpansionUsesBitReplication() {
        let red = DisplayMirrorAssembler.rgb565(0xF800)
        let green = DisplayMirrorAssembler.rgb565(0x07E0)
        let blue = DisplayMirrorAssembler.rgb565(0x001F)
        let white = DisplayMirrorAssembler.rgb565(0xFFFF)
        #expect(red == (255, 0, 0))
        #expect(green == (0, 255, 0))
        #expect(blue == (0, 0, 255))
        #expect(white == (255, 255, 255))
    }

    @Test("The rendered RGBA buffer holds width × height × 4 bytes")
    func rgbaBufferLengthMatchesGeometry() throws {
        var assembler = DisplayMirrorAssembler()
        let imageResult = assembler.ingest(frame: Self.monoChunk(
            width: 128, height: 60, frameID: 1, offset: 0,
            data: [UInt8](repeating: 0xFF, count: 128 * 8), total: 128 * 8))
        let image = try #require(imageResult)
        #expect(image.width == 128)
        #expect(image.height == 60)
        #expect(image.rgba.count == 128 * 60 * 4)
    }

    @Test("A rendered frame converts to a CGImage of the panel size")
    func renderedFrameConvertsToCGImage() throws {
        var assembler = DisplayMirrorAssembler()
        let imageResult = assembler.ingest(frame: Self.monoChunk(
            width: 16, height: 8, frameID: 1, offset: 0, data: [UInt8](repeating: 0, count: 16), total: 16))
        let image = try #require(imageResult)
        let cgImage = try #require(DisplayMirrorModel.makeCGImage(image))
        #expect(cgImage.width == 16)
        #expect(cgImage.height == 8)
        #expect(cgImage.bitsPerPixel == 32)

        let truncated = DisplayMirrorImage(width: 16, height: 8, rgba: Data(count: 10))
        #expect(DisplayMirrorModel.makeCGImage(truncated) == nil)
    }

    @Test("A palette arriving after its frame re-renders that frame in colour")
    func lateMatchingPaletteRerendersLastFrame() throws {
        var assembler = DisplayMirrorAssembler()
        var data = [UInt8](repeating: 0, count: 8)
        data[0] = 0x01
        let monoResult = assembler.ingest(frame: Self.monoChunk(
            width: 8, height: 8, frameID: 1, offset: 0, data: data, total: 8, paletteSignature: 42))
        let mono = try #require(monoResult)
        #expect(Self.pixel(mono.rgba, 0) == Self.white)

        let coloredResult = assembler.ingest(palette: Self.paletteChunk(
            signature: 42, offset: 0, total: 1, defaultOn: 0xFFFF,
            regions: [Self.region(width: 1, height: 1, on: 0xF800)]
        ))
        let colored = try #require(coloredResult)
        #expect(Self.pixel(colored.rgba, 0) == Self.red)

        let unrelated = assembler.ingest(palette: Self.paletteChunk(
            signature: 43, offset: 0, total: 0, regions: []))
        #expect(unrelated == nil)
    }
}
