import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Model

/// Reassembles display-mirror chunks and holds the latest rendered frame.
@Observable
@MainActor
final class DisplayMirrorModel {
    private(set) var image: CGImage?
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    @ObservationIgnored private var assembler = DisplayMirrorAssembler()

    func ingest(frame: Meshtastic_DisplayFrame) {
        guard let rendered = assembler.ingest(frame: frame) else { return }
        show(rendered)
    }

    func ingest(palette: Meshtastic_DisplayPalette) {
        guard let rendered = assembler.ingest(palette: palette) else { return }
        show(rendered)
    }

    func reset() {
        assembler.reset()
        image = nil
        pixelWidth = 0
        pixelHeight = 0
    }

    private func show(_ rendered: DisplayMirrorImage) {
        guard let cgImage = Self.makeCGImage(rendered) else {
            AppLogger.shared.log("[DisplayMirror] Could not create an image for \(rendered.width)x\(rendered.height)")
            return
        }
        image = cgImage
        pixelWidth = rendered.width
        pixelHeight = rendered.height
    }

    /// Wraps the 32-bit RGBA buffer in a `CGImage` without copying pixel by pixel.
    nonisolated static func makeCGImage(_ rendered: DisplayMirrorImage) -> CGImage? {
        guard rendered.width > 0, rendered.height > 0,
              rendered.rgba.count == rendered.width * rendered.height * 4,
              let provider = CGDataProvider(data: rendered.rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: rendered.width,
            height: rendered.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rendered.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// MARK: - View

/// Live, pixel-exact mirror of the connected device's display (firmware 2.8,
/// local connection only). Mirroring is switched on while the window is open and
/// connected, and always switched off again when the window closes.
struct DisplayMirrorView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var model = DisplayMirrorModel()
    @State private var mirrorStarted = false

    private static let background = Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255)

    var body: some View {
        ZStack {
            Self.background
            content
        }
        .frame(minWidth: 320, minHeight: 200)
        .navigationSubtitle(subtitle)
        .task(id: appState.connectionState.isConnected) {
            if appState.connectionState.isConnected {
                await startMirror()
            } else {
                detachCallbacks()
                mirrorStarted = false
                model.reset()
            }
        }
        .onDisappear {
            stopMirror()
        }
    }

    private var subtitle: String {
        model.image == nil ? "" : "\(model.pixelWidth) × \(model.pixelHeight)"
    }

    @ViewBuilder
    private var content: some View {
        if let image = model.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .padding(12)
        } else if appState.connectionState.isConnected {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the first frame from the device…")
            }
            .foregroundStyle(Color(red: 0x20 / 255, green: 0xC9 / 255, blue: 0x97 / 255))
        } else {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "display.trianglebadge.exclamationmark",
                description: Text("Connect to a device with a display to mirror its screen.")
            )
        }
    }

    // MARK: - Mirror lifecycle

    private func startMirror() async {
        let protocolService = coordinator.protocol_
        protocolService.onDisplayFrame = { [model] frame in model.ingest(frame: frame) }
        protocolService.onDisplayPalette = { [model] palette in model.ingest(palette: palette) }
        mirrorStarted = true
        await protocolService.setDisplayMirror(true)
        // The window may have closed while the session key was being fetched; the
        // stop sent from onDisappear could then precede this start.
        guard !Task.isCancelled else {
            await protocolService.setDisplayMirror(false)
            return
        }
        await protocolService.requestDisplayFrame()
    }

    private func stopMirror() {
        detachCallbacks()
        guard mirrorStarted else { return }
        mirrorStarted = false
        guard appState.connectionState.isConnected else { return }
        let protocolService = coordinator.protocol_
        Task { await protocolService.setDisplayMirror(false) }
    }

    private func detachCallbacks() {
        coordinator.protocol_.onDisplayFrame = nil
        coordinator.protocol_.onDisplayPalette = nil
    }
}
