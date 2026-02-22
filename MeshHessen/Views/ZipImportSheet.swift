import SwiftUI
import UniformTypeIdentifiers

/// Sheet for importing offline tile archives (.zip) into the app's tile cache.
///
/// Detects tile source from top-level folder names inside the zip:
///   - "osm"                → osm layer
///   - "osmtopo", "opentopo" → opentopo layer
///   - "osmdark", "dark"     → dark layer
///
/// Tiles are converted from the zip's nested `{source}/{z}/{x}/{y}.png` structure
/// to the flat `{layer}/{z}_{x}_{y}.png` cache format used by ``CachedTileOverlay``.
struct ZipImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var resultMessage: String?

    /// Maps recognised zip folder names to the canonical cache layer name.
    private static let folderToLayer: [String: String] = [
        "osm":      "osm",
        "osmtopo":  "opentopo",
        "opentopo": "opentopo",
        "osmdark":  "dark",
        "dark":     "dark",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Tile Archive")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Import a .zip archive containing offline map tiles.")
                    .foregroundStyle(.secondary)

                Text("Recognised folder names:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.top, 4)

                Text("""
                osm/          → Street (OSM)
                osmtopo/      → Topo
                opentopo/     → Topo
                osmdark/      → Dark
                dark/         → Dark
                """)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Archive structure: {source}/{z}/{x}/{y}.png")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if isProcessing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result = resultMessage {
                Text(result)
                    .foregroundStyle(result.contains("Error") ? .red : .green)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Choose Archive…") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { processZip(url) }
            case .failure(let err):
                resultMessage = String(localized: "Error: \(err.localizedDescription)")
            }
        }
    }

    // MARK: - Import logic

    private func processZip(_ url: URL) {
        isProcessing = true
        progress = 0
        statusText = String(localized: "Extracting archive…")
        resultMessage = nil

        Task.detached {
            guard url.startAccessingSecurityScopedResource() else {
                await MainActor.run {
                    isProcessing = false
                    resultMessage = String(localized: "Error: Could not access file.")
                }
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let fm = FileManager.default

            // Tile cache root
            let cacheRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeshHessen/tiles")

            // Create a temporary directory for extraction
            let tempDir: URL
            do {
                tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run {
                    isProcessing = false
                    resultMessage = String(localized: "Error: Could not create temp directory.")
                }
                return
            }

            defer { try? fm.removeItem(at: tempDir) }

            do {
                // 1. Extract zip to temp directory
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", url.path, "-d", tempDir.path]
                // Suppress unzip stdout noise
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()

                guard proc.terminationStatus == 0 else {
                    await MainActor.run {
                        isProcessing = false
                        resultMessage = String(localized: "Error: unzip exited with code \(proc.terminationStatus).")
                    }
                    return
                }

                // 2. Scan top-level folders to detect tile sources
                await MainActor.run { statusText = String(localized: "Detecting tile sources…") }

                let topLevel = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

                var sourceFolders: [(url: URL, folderName: String, layer: String)] = []
                var unknownFolders: [String] = []

                for item in topLevel {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir else { continue }

                    let name = item.lastPathComponent.lowercased()
                    if let layer = Self.folderToLayer[name] {
                        sourceFolders.append((url: item, folderName: item.lastPathComponent, layer: layer))
                    } else {
                        unknownFolders.append(item.lastPathComponent)
                    }
                }

                guard !sourceFolders.isEmpty else {
                    let hint = unknownFolders.isEmpty
                        ? String(localized: "Archive contains no folders.")
                        : String(localized: "Unrecognised folders: \(unknownFolders.joined(separator: ", "))")
                    await MainActor.run {
                        isProcessing = false
                        resultMessage = String(localized: "Error: No tile sources found.") + " " + hint
                    }
                    return
                }

                // 3. Reorganise tiles into cache directory
                await MainActor.run { statusText = String(localized: "Scanning tiles…") }

                // Collect all .png files per source
                struct TileEntry {
                    let sourceFile: URL
                    let layer: String
                    let z: String
                    let x: String
                    let y: String
                }

                var tileEntries: [TileEntry] = []
                var countsPerLayer: [String: Int] = [:]

                for source in sourceFolders {
                    let enumerator = fm.enumerator(at: source.url,
                                                   includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles])
                    while let fileURL = enumerator?.nextObject() as? URL {
                        guard fileURL.pathExtension.lowercased() == "png" else { continue }
                        let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                        guard isFile else { continue }

                        // Expected path: {source}/{z}/{x}/{y}.png
                        let rel = fileURL.path.replacingOccurrences(of: source.url.path + "/", with: "")
                        let parts = rel.split(separator: "/").map(String.init)

                        // We need at least z/x/y.png → 3 components
                        guard parts.count >= 3 else { continue }

                        let zVal = parts[parts.count - 3]
                        let xVal = parts[parts.count - 2]
                        let yVal = (parts[parts.count - 1] as NSString).deletingPathExtension

                        // Basic sanity: z, x, y should be numeric
                        guard Int(zVal) != nil, Int(xVal) != nil, Int(yVal) != nil else { continue }

                        tileEntries.append(TileEntry(sourceFile: fileURL,
                                                     layer: source.layer,
                                                     z: zVal, x: xVal, y: yVal))
                        countsPerLayer[source.layer, default: 0] += 1
                    }
                }

                guard !tileEntries.isEmpty else {
                    await MainActor.run {
                        isProcessing = false
                        resultMessage = String(localized: "Error: No valid tile images found in archive.")
                    }
                    return
                }

                // 4. Copy tiles to cache
                let total = tileEntries.count
                var done = 0
                var errors = 0

                await MainActor.run {
                    statusText = String(localized: "Importing \(total) tiles…")
                    progress = 0
                }

                for entry in tileEntries {
                    let layerDir = cacheRoot.appendingPathComponent(entry.layer)
                    try fm.createDirectory(at: layerDir, withIntermediateDirectories: true)

                    let destFile = layerDir.appendingPathComponent("\(entry.z)_\(entry.x)_\(entry.y).png")

                    do {
                        if fm.fileExists(atPath: destFile.path) {
                            try fm.removeItem(at: destFile)
                        }
                        try fm.copyItem(at: entry.sourceFile, to: destFile)
                    } catch {
                        errors += 1
                    }

                    done += 1
                    if done % 100 == 0 || done == total {
                        let p = Double(done) / Double(total)
                        let d = done
                        await MainActor.run {
                            progress = p
                            statusText = String(localized: "Importing tiles… \(d)/\(total)")
                        }
                    }
                }

                // 5. Build summary
                let layerLabels: [String: String] = ["osm": "osm", "opentopo": "topo", "dark": "dark"]
                var parts: [String] = []
                for (layer, count) in countsPerLayer.sorted(by: { $0.key < $1.key }) {
                    let label = layerLabels[layer] ?? layer
                    parts.append("\(count) \(label)")
                }
                let summary = String(localized: "Imported \(done - errors) tiles: \(parts.joined(separator: ", "))")
                let errorNote = errors > 0 ? String(localized: " (\(errors) failed)") : ""

                await MainActor.run {
                    isProcessing = false
                    progress = 1.0
                    resultMessage = summary + errorNote

                    if !unknownFolders.isEmpty {
                        resultMessage! += "\n" + String(localized: "Skipped unknown folders: \(unknownFolders.joined(separator: ", "))")
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    resultMessage = String(localized: "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
