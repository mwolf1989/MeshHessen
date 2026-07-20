import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OfflineMapManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var manager: OfflineMapManager
    @State private var settings = SettingsService.shared
    @State private var packageName = String(localized: "Hessen offline")
    @State private var source = MapTileSource.osm
    @State private var downloadRenderMode = MapRenderMode.raster
    @State private var includeTopography = true
    @State private var includeEmergencyFeatures = true
    @State private var selectedPreset = "Hessen"
    @State private var north = MapBounds.hessen.north
    @State private var south = MapBounds.hessen.south
    @State private var east = MapBounds.hessen.east
    @State private var west = MapBounds.hessen.west
    @State private var minimumZoom = 1
    @State private var maximumZoom = 14
    @State private var pendingDeletion: OfflineMapPackage?
    @State private var showClearConfirmation = false

    private var bounds: MapBounds {
        .init(north: north, south: south, east: east, west: west)
    }

    private var descriptor: MapTileSourceDescriptor {
        switch settings.mapMode {
        case .meshHessen:
            return .init(source: source, urlTemplate: source.meshHessenRasterURLTemplate)
        case .publicOpenStreetMap:
            return .init(source: .osm, urlTemplate: settings.publicOSMTileURL)
        case .custom, .offline:
            let template: String
            switch source {
            case .osm: template = settings.osmTileURL
            case .topographic: template = settings.topographicTileURL
            case .dark: template = settings.darkTileURL
            }
            return .init(source: source, urlTemplate: template)
        }
    }

    private var estimate: Int {
        if downloadRenderMode == .vector {
            return VectorOfflinePackageDownloaderService.estimatedResourceCount(
                for: .init(
                    bounds: bounds,
                    maximumDetailZoom: maximumZoom,
                    includeTopography: includeTopography,
                    includeEmergencyFeatures: includeEmergencyFeatures
                )
            )
        }
        return TileCoordinateCalculator.estimatedTileCount(
            bounds: bounds,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom
        )
    }

    private var canDownload: Bool {
        bounds.isValid
            && minimumZoom >= 1
            && maximumZoom <= 19
            && minimumZoom <= maximumZoom
            && estimate > 0
            && estimate <= TileCoordinateCalculator.maximumOfflineTileCount
            && (downloadRenderMode == .vector || !MapTilePolicy.isPublicTileServer(descriptor.urlTemplate))
            && !manager.isWorking
    }

    var body: some View {
        NavigationSplitView {
            packageList
                .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            downloadForm
        }
        .frame(minWidth: 780, minHeight: 600)
        .navigationTitle("Offline Maps")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: dismiss.callAsFunction)
            }
        }
        .task {
            await manager.refresh()
        }
        .alert("Delete offline map?", isPresented: deletionAlertBinding, presenting: pendingDeletion) { package in
            Button("Delete", role: .destructive) {
                Task { await manager.delete(package) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { package in
            Text("“\(package.name)” and its \(package.tileCount) tiles will be removed.")
        }
        .alert("Clear live map cache?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                Task { await manager.clearLiveCache() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Offline packages are retained. Tiles cached while browsing online are removed.")
        }
        .alert("Map Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(manager.errorMessage ?? "")
        }
    }

    private var packageList: some View {
        VStack(spacing: 0) {
            if manager.packages.isEmpty {
                ContentUnavailableView(
                    "No Offline Maps",
                    systemImage: "map",
                    description: Text("Download an area or import a Windows-compatible tile ZIP.")
                )
            } else {
                List(manager.packages) { package in
                    OfflinePackageRow(
                        package: package,
                        onExport: { chooseExportDestination(for: package) },
                        onDelete: { pendingDeletion = package }
                    )
                }
                .listStyle(.inset)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Map storage", value: manager.totalSizeFormatted)
                HStack {
                    Button("Import ZIP…", systemImage: "square.and.arrow.down", action: chooseImport)
                    Button("Clear Live Cache…", systemImage: "trash", role: .destructive) {
                        showClearConfirmation = true
                    }
                    Spacer()
                }
            }
            .padding()
        }
    }

    private var downloadForm: some View {
        Form {
            Section("Offline Area") {
                TextField("Package name", text: $packageName)
                Picker("Preset", selection: $selectedPreset) {
                    Text("Manual").tag("")
                    ForEach(MapRegionPreset.germanStates) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .onChange(of: selectedPreset) {
                    applySelectedPreset()
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    coordinateField("North", value: $north)
                    coordinateField("South", value: $south)
                    coordinateField("East", value: $east)
                    coordinateField("West", value: $west)
                }
            }

            Section("Tiles") {
                Picker("Render mode", selection: $downloadRenderMode) {
                    Text("Raster").tag(MapRenderMode.raster)
                    Text("Vector").tag(MapRenderMode.vector)
                }
                .pickerStyle(.segmented)

                Picker("Map source", selection: $source) {
                    ForEach(MapTileSource.allCases) { source in
                        Text(source.localizedName).tag(source)
                    }
                }

                HStack {
                    Stepper("Minimum zoom: \(minimumZoom)", value: $minimumZoom, in: 1...19)
                    Stepper(
                        "Maximum zoom: \(maximumZoom)",
                        value: $maximumZoom,
                        in: 1...(downloadRenderMode == .vector ? 17 : 19)
                    )
                }

                if downloadRenderMode == .vector {
                    Toggle("Include contours and hillshade", isOn: $includeTopography)
                    Toggle("Include fire and rescue features", isOn: $includeEmergencyFeatures)
                    Text("The vector basemap is shared by all three styles. Existing resources are reused, so repeated downloads are incremental.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(
                    "Estimate",
                    value: estimate.formatted() + " " + String(
                        localized: downloadRenderMode == .vector ? "resources" : "tiles"
                    )
                )
                Text("Higher zoom levels grow exponentially. The default 1–14 covers Hessen with roughly 26,000 tiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if downloadRenderMode == .raster && MapTilePolicy.isPublicTileServer(descriptor.urlTemplate) {
                    Label(
                        "Bulk downloading from public OSM/OpenTopoMap servers is disabled by their usage policy. Select the Mesh Hessen or a custom server mode in Settings.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Download") {
                if let progress = manager.progress, manager.isWorking {
                    ProgressView(value: progress.fractionCompleted) {
                        Text(progress.phase.rawValue.capitalized)
                    } currentValueLabel: {
                        Text(progress.status)
                    }
                    Button("Cancel", role: .cancel, action: manager.cancel)
                } else {
                    Button("Download Offline Map", systemImage: "arrow.down.circle", action: beginDownload)
                        .disabled(!canDownload)
                }
            }

            Section("Attribution") {
                Text(descriptor.attribution)
                    .font(.caption)
                Text("Downloaded tiles are stored in Application Support and remain available without a network connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func coordinateField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        GridRow {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(4...7)))
                .frame(maxWidth: 180)
        }
    }

    private func applySelectedPreset() {
        guard let preset = MapRegionPreset.germanStates.first(where: { $0.name == selectedPreset }) else {
            return
        }
        north = preset.bounds.north
        south = preset.bounds.south
        east = preset.bounds.east
        west = preset.bounds.west
        if packageName.isEmpty || MapRegionPreset.germanStates.contains(where: { $0.name + " offline" == packageName }) {
            packageName = preset.name + " offline"
        }
    }

    private func beginDownload() {
        if downloadRenderMode == .vector {
            manager.beginVectorDownload(
                .init(
                    bounds: bounds,
                    maximumDetailZoom: maximumZoom,
                    includeTopography: includeTopography,
                    includeEmergencyFeatures: includeEmergencyFeatures
                )
            )
            return
        }
        manager.beginDownload(
            .init(
                name: packageName,
                descriptor: descriptor,
                bounds: bounds,
                minimumZoom: minimumZoom,
                maximumZoom: maximumZoom
            )
        )
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Offline Map")
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            manager.beginImport(from: url)
        }
    }

    private func chooseExportDestination(for package: OfflineMapPackage) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Offline Map")
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = package.name.replacingOccurrences(of: "/", with: "-") + ".zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            manager.beginExport(package, to: url)
        }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )
    }
}

private struct OfflinePackageRow: View {
    let package: OfflineMapPackage
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "map.fill")
                    .foregroundStyle(.blue)
                Text(package.name)
                    .font(.headline)
                Spacer()
                Menu("Actions", systemImage: "ellipsis.circle") {
                    Button("Export ZIP…", systemImage: "square.and.arrow.up", action: onExport)
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .menuStyle(.borderlessButton)
            }
            Text("\(package.source.localizedName) · Z\(package.minimumZoom)–\(package.maximumZoom)")
                .font(.subheadline)
            Text("\(package.tileCount.formatted()) tiles · \(package.displaySize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
