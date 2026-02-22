import SwiftUI

// MARK: - Bundesland Bounding Box Model

/// A geographic bounding box defined by north/south latitude and east/west longitude.
struct BoundingBox: Equatable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double
}

/// German federal states with pre-configured bounding boxes for tile downloading.
enum Bundesland: String, CaseIterable, Identifiable {
    case custom = "Custom"
    case badenWuerttemberg = "Baden-Württemberg"
    case bayern = "Bayern"
    case berlin = "Berlin"
    case brandenburg = "Brandenburg"
    case bremen = "Bremen"
    case hamburg = "Hamburg"
    case hessen = "Hessen"
    case mecklenburgVorpommern = "Mecklenburg-Vorpommern"
    case niedersachsen = "Niedersachsen"
    case nordrheinWestfalen = "Nordrhein-Westfalen"
    case rheinlandPfalz = "Rheinland-Pfalz"
    case saarland = "Saarland"
    case sachsen = "Sachsen"
    case sachsenAnhalt = "Sachsen-Anhalt"
    case schleswigHolstein = "Schleswig-Holstein"
    case thueringen = "Thüringen"

    var id: String { rawValue }

    /// Pre-configured bounding box for each state, matching the Windows client values.
    var boundingBox: BoundingBox? {
        switch self {
        case .custom:               return nil
        case .badenWuerttemberg:    return BoundingBox(north: 49.8, south: 47.5, east: 10.5, west: 7.5)
        case .bayern:               return BoundingBox(north: 50.6, south: 47.3, east: 13.8, west: 8.9)
        case .berlin:               return BoundingBox(north: 52.7, south: 52.3, east: 13.8, west: 13.1)
        case .brandenburg:          return BoundingBox(north: 53.6, south: 51.4, east: 14.8, west: 11.3)
        case .bremen:               return BoundingBox(north: 53.6, south: 53.0, east: 8.9, west: 8.5)
        case .hamburg:              return BoundingBox(north: 53.8, south: 53.4, east: 10.3, west: 9.7)
        case .hessen:               return BoundingBox(north: 51.7, south: 49.4, east: 10.3, west: 7.8)
        case .mecklenburgVorpommern: return BoundingBox(north: 54.7, south: 53.1, east: 14.4, west: 10.6)
        case .niedersachsen:        return BoundingBox(north: 53.9, south: 51.3, east: 11.6, west: 6.7)
        case .nordrheinWestfalen:   return BoundingBox(north: 52.5, south: 50.3, east: 9.5, west: 5.9)
        case .rheinlandPfalz:       return BoundingBox(north: 50.9, south: 48.9, east: 8.5, west: 6.1)
        case .saarland:             return BoundingBox(north: 49.6, south: 49.1, east: 7.4, west: 6.4)
        case .sachsen:              return BoundingBox(north: 51.7, south: 50.2, east: 15.0, west: 11.9)
        case .sachsenAnhalt:        return BoundingBox(north: 53.0, south: 50.9, east: 13.2, west: 10.6)
        case .schleswigHolstein:    return BoundingBox(north: 55.1, south: 53.4, east: 11.3, west: 8.4)
        case .thueringen:           return BoundingBox(north: 51.6, south: 50.2, east: 12.7, west: 9.9)
        }
    }
}

// MARK: - Tile Downloader Sheet

/// Sheet for downloading offline map tiles to a local folder.
struct TileDownloaderSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var minZoom: Double = 6
    @State private var maxZoom: Double = 12
    @State private var selectedLayer = "osm"
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var task: Task<Void, Never>?

    // Bundesland selection
    @State private var selectedBundesland: Bundesland = .hessen

    // Custom bounding box fields (strings for text input)
    @State private var customNorth = "51.7"
    @State private var customSouth = "49.4"
    @State private var customEast = "10.3"
    @State private var customWest = "7.8"

    private let layers = ["osm", "opentopo", "dark"]
    private let layerLabels = ["Street (OSM)", "Topo", "Dark"]

    /// Own tile server domains that skip rate limiting.
    private static let ownServerDomains = [
        "tile.schwarzes-seelenreich.de",
        "tile.meshhessen.de"
    ]

    /// Rate limit delay in milliseconds for external tile servers.
    private static let externalDelayMs: UInt64 = 500

    /// The active bounding box based on Bundesland selection or custom input.
    private var activeBBox: BoundingBox {
        if let bbox = selectedBundesland.boundingBox {
            return bbox
        }
        // Custom: parse text fields
        return BoundingBox(
            north: Double(customNorth) ?? 51.7,
            south: Double(customSouth) ?? 49.4,
            east: Double(customEast) ?? 10.3,
            west: Double(customWest) ?? 7.8
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Offline Tiles")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tiles are stored locally for offline use. Higher zoom levels (12+) require many tiles. Respect OSM usage policy (~2 req/s max).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Form {
                Picker("Layer", selection: $selectedLayer) {
                    ForEach(layers.indices, id: \.self) { i in
                        Text(layerLabels[i]).tag(layers[i])
                    }
                }
                .pickerStyle(.radioGroup)

                // Bundesland picker
                Picker("Region", selection: $selectedBundesland) {
                    ForEach(Bundesland.allCases) { land in
                        Text(land.rawValue).tag(land)
                    }
                }

                // Custom bounding box fields (only when "Custom" is selected)
                if selectedBundesland == .custom {
                    Section("Bounding Box (WGS84)") {
                        HStack {
                            Text("North (max lat)")
                                .frame(width: 110, alignment: .leading)
                            TextField("51.7", text: $customNorth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        HStack {
                            Text("South (min lat)")
                                .frame(width: 110, alignment: .leading)
                            TextField("49.4", text: $customSouth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        HStack {
                            Text("East (max lon)")
                                .frame(width: 110, alignment: .leading)
                            TextField("10.3", text: $customEast)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        HStack {
                            Text("West (min lon)")
                                .frame(width: 110, alignment: .leading)
                            TextField("7.8", text: $customWest)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                } else {
                    // Show the selected bounding box as read-only info
                    if let bbox = selectedBundesland.boundingBox {
                        HStack(spacing: 16) {
                            Text("N \(bbox.north, specifier: "%.1f")  S \(bbox.south, specifier: "%.1f")  E \(bbox.east, specifier: "%.1f")  W \(bbox.west, specifier: "%.1f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Zoom levels: \(Int(minZoom))–\(Int(maxZoom))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Min")
                        Slider(value: $minZoom, in: 1...18, step: 1)
                        Text("\(Int(minZoom))")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                    HStack {
                        Text("Max")
                        Slider(value: $maxZoom, in: 1...18, step: 1)
                        Text("\(Int(maxZoom))")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                }

                let count = estimatedTileCount()
                Text("Estimated tiles: ~\(count)")
                    .font(.caption)
                    .foregroundStyle(count > 50_000 ? .red : count > 5_000 ? .orange : .secondary)
            }
            .formStyle(.grouped)

            if isDownloading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if isDownloading {
                    Button("Cancel") { task?.cancel(); isDownloading = false }
                        .buttonStyle(.bordered)
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Download") { startDownload() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .onDisappear { task?.cancel() }
    }

    // MARK: - Tile Count Estimation

    private func estimatedTileCount() -> Int {
        let bbox = activeBBox
        var total = 0
        for z in Int(minZoom)...Int(maxZoom) {
            let tileCount = 1 << z
            let xMin = Int(floor((bbox.west + 180) / 360 * Double(tileCount)))
            let xMax = Int(floor((bbox.east + 180) / 360 * Double(tileCount)))
            let latRad = bbox.north * .pi / 180
            let yMin = Int(floor((1 - log(tan(latRad) + 1/cos(latRad)) / .pi) / 2 * Double(tileCount)))
            let latRad2 = bbox.south * .pi / 180
            let yMax = Int(floor((1 - log(tan(latRad2) + 1/cos(latRad2)) / .pi) / 2 * Double(tileCount)))
            total += max(0, (xMax - xMin + 1)) * max(0, (yMax - yMin + 1))
        }
        return total
    }

    // MARK: - Rate Limiting

    /// Returns true if the given URL points to one of our own tile servers.
    private static func isOwnServer(url: String) -> Bool {
        let lower = url.lowercased()
        return ownServerDomains.contains { lower.contains($0) }
    }

    // MARK: - Tile URL Resolution

    /// Resolves the tile URL for the selected layer using settings or a fallback.
    private func tileUrlTemplate() -> String {
        let settings = SettingsService.shared
        switch selectedLayer {
        case "opentopo": return settings.osmTopoTileUrl
        case "dark":     return settings.osmDarkTileUrl
        default:         return settings.osmTileUrl
        }
    }

    // MARK: - Download

    private func startDownload() {
        isDownloading = true
        progress = 0
        statusText = String(localized: "Starting...")

        let bbox = activeBBox
        let urlTemplate = tileUrlTemplate()
        let minZ = Int(minZoom)
        let maxZ = Int(maxZoom)
        let layer = selectedLayer

        task = Task {
            let tileDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeshHessen/tiles/\(layer)")
            try? FileManager.default.createDirectory(at: tileDir, withIntermediateDirectories: true)

            var downloaded = 0
            var skipped = 0
            let total = estimatedTileCount()
            guard total > 0 else {
                await MainActor.run { isDownloading = false; statusText = String(localized: "No tiles to download.") }
                return
            }

            for z in minZ...maxZ {
                let tileCount = 1 << z
                let xMin = Int(floor((bbox.west + 180) / 360 * Double(tileCount)))
                let xMax = Int(floor((bbox.east + 180) / 360 * Double(tileCount)))
                let latRad = bbox.north * .pi / 180
                let yMin = Int(floor((1 - log(tan(latRad) + 1/cos(latRad)) / .pi) / 2 * Double(tileCount)))
                let latRad2 = bbox.south * .pi / 180
                let yMax = Int(floor((1 - log(tan(latRad2) + 1/cos(latRad2)) / .pi) / 2 * Double(tileCount)))

                for x in xMin...xMax {
                    for y in yMin...yMax {
                        if Task.isCancelled {
                            await MainActor.run { isDownloading = false; statusText = String(localized: "Cancelled.") }
                            return
                        }

                        let file = tileDir.appendingPathComponent("\(z)_\(x)_\(y).png")

                        // Skip tiles that already exist locally
                        if FileManager.default.fileExists(atPath: file.path) {
                            skipped += 1
                            downloaded += 1
                            let p = Double(downloaded) / Double(total)
                            await MainActor.run {
                                progress = p
                                statusText = "z=\(z) x=\(x) y=\(y) — skipped (\(downloaded)/\(total))"
                            }
                            continue
                        }

                        // Build tile URL from template
                        let urlStr = urlTemplate
                            .replacingOccurrences(of: "{z}", with: "\(z)")
                            .replacingOccurrences(of: "{x}", with: "\(x)")
                            .replacingOccurrences(of: "{y}", with: "\(y)")

                        if let url = URL(string: urlStr),
                           let data = try? await URLSession.shared.data(from: url).0 {
                            try? data.write(to: file)
                        }

                        // Rate limiting: delay for external servers only
                        if !Self.isOwnServer(url: urlStr) {
                            try? await Task.sleep(nanoseconds: Self.externalDelayMs * 1_000_000)
                        }

                        downloaded += 1
                        let p = Double(downloaded) / Double(total)
                        await MainActor.run {
                            progress = p
                            statusText = "z=\(z) x=\(x) y=\(y) (\(downloaded)/\(total))"
                        }
                    }
                }
            }
            let finalSkipped = skipped
            await MainActor.run {
                isDownloading = false
                if finalSkipped > 0 {
                    statusText = String(localized: "Done — \(downloaded) tiles (\(finalSkipped) already cached).")
                } else {
                    statusText = String(localized: "Done — \(downloaded) tiles downloaded.")
                }
            }
        }
    }
}
