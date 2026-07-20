import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Sheet showing live and persisted traceroute results for a node.
struct TracerouteSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let targetNodeId: UInt32
    let targetName: String

    @State private var historyResults: [TracerouteResult] = []
    @State private var period: TracerouteHistoryPeriod = .last7Days
    @State private var newestPerNodePair = false
    @State private var selection = TracerouteSelection()
    @State private var isRequesting = false
    @State private var requestStartedAt: Date?
    @State private var requestTask: Task<Void, Never>?
    @State private var operationMessage: String?
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showDeleteConfirmation = false
    @State private var exportDocument: TracerouteJSONDocument?

    private let store = TracerouteStore.shared

    private var query: TracerouteHistoryQuery {
        TracerouteHistoryQuery(period: period, newestPerNodePair: newestPerNodePair)
    }

    private var visibleResults: [TracerouteResult] {
        let relatedResults = historyResults.filter {
            $0.targetNodeId == targetNodeId || $0.sourceNodeId == targetNodeId
        }
        return query.apply(to: relatedResults)
    }

    private var selectedResults: [TracerouteResult] {
        selection.resolve(in: historyResults)
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private var latestLiveResultID: UUID? {
        coordinator.protocol_.tracerouteResults.first(where: { $0.targetNodeId == targetNodeId })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TracerouteHeader(
                targetName: targetName,
                isRequesting: isRequesting,
                onRun: runTraceroute,
                onDone: dismiss.callAsFunction
            )

            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(operationMessage)
            }

            Divider()

            TracerouteHistoryControls(
                period: $period,
                newestPerNodePair: $newestPerNodePair,
                selectionCount: selection.count,
                onImport: { showImporter = true },
                onExport: prepareExport,
                onCompareOnMap: prepareMapSelection,
                onDelete: { showDeleteConfirmation = true }
            )

            if visibleResults.isEmpty {
                ContentUnavailableView(
                    "No Traceroute Results",
                    systemImage: "arrow.triangle.swap",
                    description: Text("Run a traceroute or load JSON files to compare saved network paths.")
                )
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleResults) { result in
                                TracerouteResultCard(
                                    result: result,
                                    isSelected: selectionBinding(for: result)
                                )
                            }
                        }
                        .padding(.trailing, 6)
                    }
                    .frame(minWidth: 430)

                    TracerouteComparisonView(results: selectedResults)
                        .frame(minWidth: 300, idealWidth: 380)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 520)
        .task {
            await refreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tracerouteStoreDidChange)) { _ in
            Task { await refreshHistory() }
        }
        .onChange(of: latestLiveResultID) {
            completeActiveRequestIfNeeded()
            Task { await refreshHistory() }
        }
        .onDisappear {
            requestTask?.cancel()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "MeshHessen-Traceroutes"
        ) { result in
            switch result {
            case .success:
                operationMessage = String(localized: "Traceroute export completed.")
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert("Delete selected traceroutes?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: deleteSelectedResults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(selection.count) saved traceroute(s).")
        }
        .alert("Traceroute", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }

    private func selectionBinding(for result: TracerouteResult) -> Binding<Bool> {
        Binding(
            get: { selection.contains(result) },
            set: { isSelected in
                selection.setSelected(isSelected, result: result)
            }
        )
    }

    private func refreshHistory() async {
        let report = await Task.detached(priority: .utility) {
            store.loadReport()
        }.value
        historyResults = report.results
        selection.remove(ids: selection.resultIDs.subtracting(report.results.map(\.id)))
        if !report.failures.isEmpty {
            operationMessage = String(
                localized: "Loaded history; skipped \(report.failures.count) unreadable file(s)."
            )
        }
    }

    private func runTraceroute() {
        requestTask?.cancel()
        let startedAt = Date()
        requestStartedAt = startedAt
        isRequesting = true
        operationMessage = String(localized: "Waiting for traceroute response…")

        requestTask = Task { @MainActor in
            let wasSent = await coordinator.sendTraceroute(to: targetNodeId)
            guard wasSent else {
                requestStartedAt = nil
                isRequesting = false
                operationMessage = String(localized: "Traceroute could not be sent")
                return
            }

            do {
                try await Task.sleep(for: .seconds(30))
                guard requestStartedAt == startedAt else { return }
                requestStartedAt = nil
                isRequesting = false
                operationMessage = String(localized: "No traceroute response received")
            } catch {
                // A result, another request, or dismissal cancels the timeout task.
            }
        }
    }

    private func completeActiveRequestIfNeeded() {
        guard let requestStartedAt,
              let result = coordinator.protocol_.tracerouteResults.first(where: {
                  $0.targetNodeId == targetNodeId && $0.receivedAt >= requestStartedAt
              })
        else { return }

        requestTask?.cancel()
        requestTask = nil
        self.requestStartedAt = nil
        isRequesting = false
        operationMessage = String(localized: "Traceroute completed")
        selection.setSelected(true, result: result)
    }

    private func prepareExport() {
        do {
            let data = try store.exportData(for: selectedResults)
            exportDocument = TracerouteJSONDocument(data: data)
            showExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareMapSelection() {
        guard !selectedResults.isEmpty else {
            errorMessage = TracerouteStoreError.emptyExport.localizedDescription
            return
        }
        TracerouteMapSelectionStore.shared.replace(with: selectedResults)
        operationMessage = String(
            localized: "Prepared \(selectedResults.count) traceroute(s) for map comparison."
        )
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            Task {
                let importResult = await Task.detached(priority: .utility) {
                    do {
                        var imported: [TracerouteResult] = []
                        for url in urls {
                            let accessGranted = url.startAccessingSecurityScopedResource()
                            defer {
                                if accessGranted { url.stopAccessingSecurityScopedResource() }
                            }
                            imported.append(contentsOf: try store.importFile(at: url))
                        }
                        return Result<[TracerouteResult], Error>.success(imported)
                    } catch {
                        return Result<[TracerouteResult], Error>.failure(error)
                    }
                }.value

                switch importResult {
                case .success(let imported):
                    await refreshHistory()
                    for result in imported {
                        selection.setSelected(true, result: result)
                    }
                    operationMessage = String(localized: "Imported \(imported.count) traceroute(s).")
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteSelectedResults() {
        let ids = selection.resultIDs
        guard !ids.isEmpty else { return }
        Task {
            let deletionResult = await Task.detached(priority: .utility) {
                Result { try store.delete(ids: ids) }
            }.value
            switch deletionResult {
            case .success:
                TracerouteMapSelectionStore.shared.remove(ids: ids)
                selection.removeAll()
                await refreshHistory()
                operationMessage = String(localized: "Deleted \(ids.count) traceroute(s).")
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Header and Controls

private struct TracerouteHeader: View {
    let targetName: String
    let isRequesting: Bool
    let onRun: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Traceroute")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Target: \(targetName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRun) {
                ZStack {
                    Label("Run Traceroute", systemImage: "arrow.triangle.swap")
                        .opacity(isRequesting ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isRequesting ? 1 : 0)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)

            Button("Done", action: onDone)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

private struct TracerouteHistoryControls: View {
    @Binding var period: TracerouteHistoryPeriod
    @Binding var newestPerNodePair: Bool

    let selectionCount: Int
    let onImport: () -> Void
    let onExport: () -> Void
    let onCompareOnMap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(TracerouteHistoryPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Toggle("Latest per node pair", isOn: $newestPerNodePair)
                .toggleStyle(.checkbox)
                .help("Only show the newest traceroute for each direction-independent node pair.")

            Spacer()

            Button("Load JSON", systemImage: "folder", action: onImport)
            Button("Export", systemImage: "square.and.arrow.up", action: onExport)
                .disabled(selectionCount == 0)
            Button("Compare on Map", systemImage: "map", action: onCompareOnMap)
                .disabled(selectionCount == 0)
            Button("Delete", systemImage: "trash", action: onDelete)
                .disabled(selectionCount == 0)
                .foregroundStyle(selectionCount == 0 ? Color.secondary : Color.red)

            Text("\(selectionCount) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 68, alignment: .trailing)
        }
        .controlSize(.small)
    }
}

// MARK: - Result Presentation

private struct TracerouteResultCard: View {
    let result: TracerouteResult
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $isSelected) {
                    Text(result.receivedAt, format: .dateTime.day().month().year().hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)

                if let roundTripMs = result.roundTripMs {
                    Text("RTT: \(roundTripMs) ms")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if result.containsMqttHop {
                    Label("MQTT", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(localizedHopCount(result.hops.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.hops) { hop in
                let index = result.hops.firstIndex(where: { $0.id == hop.id }) ?? 0
                TracerouteHopRow(
                    number: index + 1,
                    hop: hop,
                    distanceToNext: result.distanceToNextHop(after: index),
                    showsArrow: index < result.hops.count - 1
                )
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        }
    }
}

private struct TracerouteHopRow: View {
    let number: Int
    let hop: TracerouteHop
    let distanceToNext: Double?
    let showsArrow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)

                if hop.viaMqtt {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("MQTT hop")
                }

                Text(hop.nodeName)
                    .font(.callout)
                    .fontWeight(.medium)

                if hop.latitude == nil || hop.longitude == nil {
                    Image(systemName: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Position unknown")
                }

                Spacer()

                if let snr = hop.snr {
                    Text(String(format: "%.1f dB", snr))
                        .font(.caption)
                        .foregroundStyle(snrColor(snr))
                }

                Text(String(format: "!%08x", hop.nodeId))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)

            if showsArrow {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                    if let distanceToNext {
                        Text(formattedDistance(distanceToNext))
                    } else {
                        Text("Unknown distance")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 27)
            }
        }
    }

    private func formattedDistance(_ metres: Double) -> String {
        if metres >= 1_000 {
            return String(format: "%.1f km", metres / 1_000)
        }
        return String(format: "%.0f m", metres)
    }

    private func snrColor(_ snr: Float) -> Color {
        if snr >= 5 { return .green }
        if snr >= 0 { return .orange }
        return .red
    }
}

private struct TracerouteComparisonView: View {
    let results: [TracerouteResult]

    private var uniqueRoutes: Int {
        Set(results.map { $0.hops.map(\.nodeId) }).count
    }

    var body: some View {
        Group {
            if results.count < 2 {
                ContentUnavailableView(
                    "Select Routes to Compare",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select at least two saved traceroutes in the history.")
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text(
                                uniqueRoutes == 1
                                    ? String(localized: "Same route")
                                    : String(localized: "\(uniqueRoutes) different routes")
                            )
                                .font(.headline)
                                .foregroundStyle(uniqueRoutes == 1 ? .green : .orange)
                                .gridCellColumns(6)
                        }
                        Divider().gridCellColumns(6)
                        GridRow {
                            Text("Time").fontWeight(.semibold)
                            Text("Target").fontWeight(.semibold)
                            Text("Hops").fontWeight(.semibold)
                            Text("RTT").fontWeight(.semibold)
                            Text("MQTT").fontWeight(.semibold)
                            Text("Route").fontWeight(.semibold)
                        }
                        ForEach(results) { result in
                            GridRow {
                                Text(result.receivedAt, format: .dateTime.day().month().hour().minute())
                                Text(result.targetName)
                                Text("\(result.hops.count)")
                                Text(result.roundTripMs.map { "\($0) ms" } ?? "–")
                                Image(systemName: result.containsMqttHop ? "bolt.fill" : "minus")
                                    .foregroundStyle(result.containsMqttHop ? .orange : .secondary)
                                Text(result.routeDescription)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            Divider().gridCellColumns(6)
                        }
                    }
                    .font(.caption)
                    .padding(12)
                }
            }
        }
        .background(Color.secondary.opacity(0.035))
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct TracerouteJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
