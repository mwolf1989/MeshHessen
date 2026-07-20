import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct TDeckWizardView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var destinationURL: URL?
    @State private var showFolderImporter = false
    @State private var regionMode = TDeckRegionMode.germanStates
    @State private var selectedStateNames: Set<String> = ["Hessen"]
    @State private var customBounds = TDeckBounds(
        north: 51.6567,
        south: 49.3951,
        east: 10.2367,
        west: 7.7731
    )
    @State private var showRegionPicker = false
    @State private var maximumZoom = 12
    @State private var mapSource = TDeckMapSource.osm
    @State private var progress: TDeckTransferProgress?
    @State private var failedTileCount = 0
    @State private var isTransferring = false
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportSourceFilter: TDeckMapSource?
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var transferTask: Task<Void, Never>?

    private let service = TDeckTileService.shared
    private let allowedZooms = [8, 10, 12, 14, 16, 17]

    init(startAtExport: Bool = false) {
        _step = State(initialValue: startAtExport ? 6 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }

            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                destinationURL = try result.get().first
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showRegionPicker) {
            TDeckRegionPickerView(bounds: $customBounds)
        }
        .alert(
            "T-Deck Map Assistant",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isTransferring || isExporting)
        .onDisappear {
            transferTask?.cancel()
        }
    }

    // MARK: - Layout

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "map.fill")
                .font(.system(size: 30))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("T-Deck Map Assistant")
                    .font(.title2.bold())
                Text("Step \(step) of 6 · \(stepTitle)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressView(value: Double(step), total: 6)
                .frame(width: 180)
                .accessibilityLabel("Wizard progress")
                .accessibilityValue("Step \(step) of 6")
        }
        .padding(20)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: welcomeStep
        case 2: destinationStep
        case 3: formatStep
        case 4: regionStep
        case 5: mapOptionsStep
        default: transferStep
        }
    }

    private var footer: some View {
        HStack {
            Button(isTransferring ? "Cancel transfer" : "Cancel") {
                if isTransferring {
                    transferTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Back") {
                step = max(1, step - 1)
            }
            .disabled(step == 1 || isTransferring || isExporting)

            Button(nextButtonTitle) {
                if step == 6 {
                    dismiss()
                } else {
                    step += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue || isTransferring || isExporting)
        }
        .padding(16)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Offline maps for your Meshtastic T-Deck", systemImage: "sdcard.fill")
                .font(.title3.bold())

            Text("This assistant prepares the T-Deck folder structure and transfers raster map tiles to a folder you select on an SD card.")

            VStack(alignment: .leading, spacing: 10) {
                WizardFeatureRow(icon: "externaldrive", text: "Select and inspect an SD-card volume")
                WizardFeatureRow(icon: "map", text: "Choose German states, all of Germany, or a custom map region")
                WizardFeatureRow(icon: "plus.square.on.square", text: "Copy additively: existing tiles are kept and skipped")
                WizardFeatureRow(icon: "shippingbox", text: "Cache downloaded tiles locally and export them as a ZIP archive")
            }

            Label("Offline packages in this assistant are limited to Germany.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Select SD card")
                .font(.title3.bold())
            Text("For safety, macOS requires you to select the SD-card root folder yourself.")
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(destinationURL?.lastPathComponent ?? String(localized: "No folder selected"))
                        .font(.headline)
                    Text(destinationURL?.path ?? String(localized: "Insert the SD card and choose its mounted volume."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Choose Folder…") {
                    showFolderImporter = true
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if let volumeInfo {
                volumeDetails(volumeInfo)
            }
        }
    }

    private var formatStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check formatting")
                .font(.title3.bold())

            if let volumeInfo {
                Label(
                    volumeInfo.isTDeckCompatible
                        ? "The volume appears to use a T-Deck-compatible format (\(volumeInfo.formatDescription))."
                        : "The detected format is \(volumeInfo.formatDescription). exFAT is recommended for T-Deck.",
                    systemImage: volumeInfo.isTDeckCompatible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(volumeInfo.isTDeckCompatible ? .green : .orange)
            } else {
                Label("The volume format could not be determined.", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }

            Text("Use exFAT with the smallest available allocation unit (for example 4096 bytes). Map folders contain many small files, so a small allocation unit saves considerable space. FAT32 can be used for older cards and devices.")

            Label(
                "Formatting erases the complete card. MeshHessen never formats or erases volumes itself.",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .foregroundStyle(.red)

            Button("Open Disk Utility…") {
                openDiskUtility()
            }
            .help("Open Apple's Disk Utility to format the selected card")
        }
    }

    private var regionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Select map region")
                .font(.title3.bold())

            Picker("Region", selection: $regionMode) {
                ForEach(TDeckRegionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch regionMode {
            case .germanStates:
                statesSelector
            case .germany:
                Label("All German states are included.", systemImage: "map.fill")
            case .custom:
                customRegionEditor
            }

            if let bounds = selectedBounds {
                boundsSummary(bounds)
            }
        }
    }

    private var mapOptionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Zoom and map style")
                .font(.title3.bold())

            Picker("Maximum zoom", selection: $maximumZoom) {
                ForEach(allowedZooms, id: \.self) { zoom in
                    Text("Z\(zoom)").tag(zoom)
                }
            }
            .pickerStyle(.segmented)

            if maximumZoom >= 16 {
                Label("Zoom 16–17 can require millions of tiles even for modest regions.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if maximumZoom >= 14 {
                Label("Zoom 14 provides street-level detail and can require substantial storage.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Picker("Map style", selection: $mapSource) {
                ForEach(TDeckMapSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.radioGroup)

            estimateCard

            if TDeckTileService.isPublicTileServer(mapSource.urlTemplate()) {
                Label(
                    "Bulk downloads from public OSM/OpenTopoMap servers are prohibited. Configure a community or self-hosted tile server in Settings.",
                    systemImage: "hand.raised.fill"
                )
                .foregroundStyle(.red)
            }
        }
    }

    private var transferStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Summary and transfer")
                .font(.title3.bold())

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                summaryRow("Destination", destinationURL?.path ?? "—")
                summaryRow("Region", regionSummary)
                summaryRow("Zoom", "1–\(maximumZoom)")
                summaryRow("Map style", mapSource.displayName)
                summaryRow("Tiles", estimatedTileCount.formatted())
                summaryRow("Estimated size", TDeckTileService.formattedSize(estimatedSizeBytes))
            }

            Label(
                "Transfer is additive. Tiles already on the card are skipped; cached tiles are copied before anything is downloaded.",
                systemImage: "plus.square.on.square"
            )
            .foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: progress.fractionCompleted) {
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted()) tiles")
                } currentValueLabel: {
                    Text("\(Int(progress.fractionCompleted * 100))%")
                }
                Text("Z\(progress.tile.zoom) / X\(progress.tile.x) / Y\(progress.tile.y) · \(progressSourceLabel(progress.source))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if isExporting {
                ProgressView(value: exportProgress) {
                    Text("Creating ZIP archive…")
                }
            }

            if let resultMessage {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack {
                Button(isTransferring ? "Transferring…" : "Start Transfer") {
                    startTransfer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTransferring || isExporting || !canStartTransfer)

                Button("Export Local Cache as ZIP…") {
                    exportCache()
                }
                .disabled(isTransferring || isExporting)

                Picker("ZIP content", selection: $exportSourceFilter) {
                    Text("All map styles").tag(Optional<TDeckMapSource>.none)
                    ForEach(TDeckMapSource.allCases) { source in
                        Text(source.displayName).tag(Optional(source))
                    }
                }
                .frame(maxWidth: 180)
            }
        }
    }

    // MARK: - Step Components

    private var statesSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Select All") {
                    selectedStateNames = Set(TDeckGermanState.all.map(\.name))
                }
                Button("Select None") {
                    selectedStateNames.removeAll()
                }
                Spacer()
                Text("\(selectedStateNames.count) selected")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading) {
                ForEach(TDeckGermanState.all) { state in
                    Toggle(
                        state.name,
                        isOn: Binding(
                            get: { selectedStateNames.contains(state.name) },
                            set: { selected in
                                if selected {
                                    selectedStateNames.insert(state.name)
                                } else {
                                    selectedStateNames.remove(state.name)
                                }
                            }
                        )
                    )
                }
            }
        }
    }

    private var customRegionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("North")
                    TextField("North", value: $customBounds.north, format: .number.precision(.fractionLength(4...6)))
                    Text("South")
                    TextField("South", value: $customBounds.south, format: .number.precision(.fractionLength(4...6)))
                }
                GridRow {
                    Text("West")
                    TextField("West", value: $customBounds.west, format: .number.precision(.fractionLength(4...6)))
                    Text("East")
                    TextField("East", value: $customBounds.east, format: .number.precision(.fractionLength(4...6)))
                }
            }
            .textFieldStyle(.roundedBorder)

            Button("Select on Map…") {
                showRegionPicker = true
            }

            if !customBounds.isValid {
                Label("Enter valid coordinates with north above south and east to the right of west.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func volumeDetails(_ info: TDeckVolumeInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            summaryRow("Volume", info.name)
            summaryRow("Format", info.formatDescription)
            if let total = info.totalBytes {
                summaryRow("Capacity", TDeckTileService.formattedSize(total))
            }
            if let available = info.availableBytes {
                summaryRow("Available", TDeckTileService.formattedSize(available))
            }
            summaryRow("Writable", info.isReadOnly ? String(localized: "No") : String(localized: "Yes"))
        }
    }

    private var estimateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimate")
                .font(.headline)
            Text("\(estimatedTileCount.formatted()) tiles · approximately \(TDeckTileService.formattedSize(estimatedSizeBytes))")
                .font(.title3.monospacedDigit())

            if let available = volumeInfo?.availableBytes {
                Text("Available on selected volume: \(TDeckTileService.formattedSize(available))")
                    .foregroundStyle(available >= estimatedSizeBytes ? Color.secondary : Color.red)
            }
            Text("The actual size depends on map content and the card's allocation unit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func boundsSummary(_ bounds: TDeckBounds) -> some View {
        Text(
            "Bounds: N \(bounds.north.formatted(.number.precision(.fractionLength(4)))) · "
                + "S \(bounds.south.formatted(.number.precision(.fractionLength(4)))) · "
                + "W \(bounds.west.formatted(.number.precision(.fractionLength(4)))) · "
                + "E \(bounds.east.formatted(.number.precision(.fractionLength(4))))"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func summaryRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }

    // MARK: - State

    private var stepTitle: String {
        switch step {
        case 1: return String(localized: "Welcome")
        case 2: return String(localized: "Select SD card")
        case 3: return String(localized: "Check formatting")
        case 4: return String(localized: "Select map region")
        case 5: return String(localized: "Zoom and map style")
        default: return String(localized: "Summary and transfer")
        }
    }

    private var nextButtonTitle: LocalizedStringKey {
        step == 6 ? "Close" : "Next"
    }

    private var selectedBounds: TDeckBounds? {
        switch regionMode {
        case .germanStates:
            let stateBounds = TDeckGermanState.all
                .filter { selectedStateNames.contains($0.name) }
                .map(\.bounds)
            return TDeckBounds.union(stateBounds)
        case .germany:
            return .germany
        case .custom:
            return customBounds.isValid ? customBounds : nil
        }
    }

    private var regionSummary: String {
        switch regionMode {
        case .germanStates:
            return selectedStateNames.sorted().joined(separator: ", ")
        case .germany:
            return String(localized: "All of Germany")
        case .custom:
            return String(localized: "Custom coordinates")
        }
    }

    private var volumeInfo: TDeckVolumeInfo? {
        destinationURL.flatMap { TDeckTileService.volumeInfo(at: $0) }
    }

    private var estimatedTileCount: Int {
        guard let selectedBounds else { return 0 }
        return TDeckTileService.estimatedTileCount(bounds: selectedBounds, maximumZoom: maximumZoom)
    }

    private var estimatedSizeBytes: Int64 {
        TDeckTileService.estimatedSizeBytes(tileCount: estimatedTileCount)
    }

    private var canStartTransfer: Bool {
        guard destinationURL != nil,
              selectedBounds != nil,
              !TDeckTileService.isPublicTileServer(mapSource.urlTemplate())
        else { return false }
        return volumeInfo?.isReadOnly != true
    }

    private var canContinue: Bool {
        switch step {
        case 2:
            return destinationURL != nil
        case 4:
            return selectedBounds != nil
        case 5:
            return !TDeckTileService.isPublicTileServer(mapSource.urlTemplate())
        case 6:
            return !isTransferring && !isExporting
        default:
            return true
        }
    }

    // MARK: - Actions

    private func startTransfer() {
        guard let destinationURL, let selectedBounds, canStartTransfer else { return }
        progress = nil
        failedTileCount = 0
        resultMessage = nil
        isTransferring = true

        transferTask = Task {
            let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { destinationURL.stopAccessingSecurityScopedResource() }
            }

            do {
                try await service.transferTiles(
                    source: mapSource,
                    bounds: selectedBounds,
                    maximumZoom: maximumZoom,
                    destinationRoot: destinationURL
                ) { update in
                    await MainActor.run {
                        progress = update
                        if update.source == .failed { failedTileCount += 1 }
                    }
                }

                if Task.isCancelled {
                    resultMessage = String(localized: "Transfer cancelled.")
                } else if failedTileCount == 0 {
                    resultMessage = String(localized: "Transfer completed successfully.")
                } else {
                    resultMessage = String(localized: "Transfer completed with \(failedTileCount) failed tiles. Run it again to retry only missing tiles.")
                }
            } catch is CancellationError {
                resultMessage = String(localized: "Transfer cancelled. Existing files were kept.")
            } catch {
                errorMessage = error.localizedDescription
            }
            isTransferring = false
            transferTask = nil
        }
    }

    private func exportCache() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export T-Deck Tile Cache")
        panel.nameFieldStringValue = exportSourceFilter.map {
            "maptiles_\($0.sdCardFolderName).zip"
        } ?? "maptiles_all.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExporting = true
        exportProgress = 0
        resultMessage = nil
        Task {
            let hasSecurityScope = outputURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { outputURL.stopAccessingSecurityScopedResource() }
            }
            do {
                try await service.exportCachedTiles(
                    to: outputURL,
                    sourceFilter: exportSourceFilter
                ) { completed, total, _ in
                    await MainActor.run {
                        exportProgress = total > 0 ? Double(completed) / Double(total) : 0
                    }
                }
                resultMessage = String(localized: "ZIP archive exported successfully.")
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func openDiskUtility() {
        let applicationURL = URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                Task { @MainActor in errorMessage = error.localizedDescription }
            }
        }
    }

    private func progressSourceLabel(_ source: TDeckTransferProgress.Source) -> String {
        switch source {
        case .alreadyOnCard: return String(localized: "already on card")
        case .localCache:    return String(localized: "copied from cache")
        case .downloaded:    return String(localized: "downloaded")
        case .failed:        return String(localized: "failed")
        }
    }
}

private struct WizardFeatureRow: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.blue)
        }
    }
}

private struct TDeckRegionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var bounds: TDeckBounds

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4),
            span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 11.5)
        )
    )
    @State private var firstCorner: CLLocationCoordinate2D?
    @State private var secondCorner: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Select Custom Region")
                        .font(.title2.bold())
                    Text(instructionText)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") {
                    firstCorner = nil
                    secondCorner = nil
                }
            }
            .padding()

            MapReader { proxy in
                Map(position: $camera) {
                    if let firstCorner {
                        Marker("First corner", coordinate: firstCorner)
                            .tint(.blue)
                    }
                    if let secondCorner {
                        Marker("Second corner", coordinate: secondCorner)
                            .tint(.orange)
                    }
                    if let selectedPolygon {
                        MapPolygon(coordinates: selectedPolygon)
                            .foregroundStyle(.blue.opacity(0.18))
                            .stroke(.blue, lineWidth: 2)
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                            if firstCorner == nil || secondCorner != nil {
                                firstCorner = coordinate
                                secondCorner = nil
                            } else {
                                secondCorner = coordinate
                            }
                        }
                )
            }

            HStack {
                if let selectedBounds {
                    Text("N \(selectedBounds.north, format: .number.precision(.fractionLength(4))) · S \(selectedBounds.south, format: .number.precision(.fractionLength(4))) · W \(selectedBounds.west, format: .number.precision(.fractionLength(4))) · E \(selectedBounds.east, format: .number.precision(.fractionLength(4)))")
                        .font(.caption.monospacedDigit())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use Region") {
                    guard let selectedBounds else { return }
                    bounds = selectedBounds
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBounds == nil)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var instructionText: LocalizedStringKey {
        if firstCorner == nil || secondCorner != nil {
            return "Click the first corner of the region. A new click starts a new selection."
        }
        return "Click the opposite corner to complete the region."
    }

    private var selectedBounds: TDeckBounds? {
        guard let firstCorner, let secondCorner else { return nil }
        let result = TDeckBounds(
            north: max(firstCorner.latitude, secondCorner.latitude),
            south: min(firstCorner.latitude, secondCorner.latitude),
            east: max(firstCorner.longitude, secondCorner.longitude),
            west: min(firstCorner.longitude, secondCorner.longitude)
        )
        return result.isValid ? result : nil
    }

    private var selectedPolygon: [CLLocationCoordinate2D]? {
        guard let bounds = selectedBounds else { return nil }
        return [
            .init(latitude: bounds.north, longitude: bounds.west),
            .init(latitude: bounds.north, longitude: bounds.east),
            .init(latitude: bounds.south, longitude: bounds.east),
            .init(latitude: bounds.south, longitude: bounds.west),
        ]
    }
}
