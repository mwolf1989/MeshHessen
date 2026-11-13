import SwiftUI

/// Hidden tool (triple-click in the telemetry window): estimates where a node is from the
/// signals its RF neighbours measured. Always presented as a rough estimate — the result
/// is never stored as the node's position.
struct TriangulationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appState) private var appState

    let initialTargetId: UInt32
    /// Called after the layer was put on the map (the caller closes its own window).
    var onShownOnMap: () -> Void = {}

    @State private var context: TriangulationDataProvider.Context?
    @State private var targetId: UInt32 = 0
    @State private var useFittedModel = false
    @State private var outcome: TriangulationOutcome?
    @State private var isComputing = false
    @State private var hasComputed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Triangulate Position", systemImage: "scope")
                    .font(.title2.bold())
                Spacer()
            }
            .padding()

            Divider()

            if let context {
                Form {
                    Section {
                        Label("Rough estimate — terrain dominates LoRa links.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Section("Target") {
                        Picker("Node", selection: $targetId) {
                            ForEach(context.candidates, id: \.self) { id in
                                Text(name(id, in: context)).tag(id)
                            }
                        }
                    }
                    ModelSection(calibration: context.fittedCalibration, useFittedModel: $useFittedModel)
                    resultSection
                }
                .formStyle(.grouped)
            } else {
                ProgressView("Loading link data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Show on Map", systemImage: "map", action: showOnMap)
                    .keyboardShortcut(.defaultAction)
                    .disabled(outcome == nil || isComputing)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .task { await loadContext() }
        .task(id: computeKey) { await compute() }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        Section("Result") {
            if isComputing || !hasComputed {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let outcome {
                let estimate = outcome.estimate
                LabeledContent("Estimated position", value: coordinateText(estimate.lat, estimate.lon))
                    .textSelection(.enabled)
                LabeledContent("Uncertainty", value: "±\(TriangulationMapLayer.km(estimate.uncertaintyKm)) km")
                LabeledContent("RF anchors", value: "\(outcome.rfAnchorCount)")
                if let altLat = estimate.altLat, let altLon = estimate.altLon {
                    LabeledContent("Alternative position", value: coordinateText(altLat, altLon))
                        .textSelection(.enabled)
                    Text("The anchors fit a second region about as well (one-sided anchor geometry).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(
                    "Terrain",
                    value: outcome.usedTerrain
                        ? String(localized: "Terrain data used")
                        : String(localized: "Flat model (no terrain data)")
                )
                ForEach(outcome.anchors) { anchor in
                    AnchorRow(anchor: anchor)
                }
            } else {
                Text("Too few anchors: at least 2 RF neighbors with a known position and a signal value are required. Traceroutes and NeighborInfo packets fill the link database over time.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private struct ComputeKey: Equatable {
        var loaded: Bool
        var targetId: UInt32
        var useFittedModel: Bool
    }

    private var computeKey: ComputeKey {
        ComputeKey(loaded: context != nil, targetId: targetId, useFittedModel: useFittedModel)
    }

    private func loadContext() async {
        var livePositions: [UInt32: TriangulationPosition] = [:]
        var names: [UInt32: String] = [:]
        for node in appState.nodes.values {
            names[node.id] = node.name
            if let latitude = node.latitude, let longitude = node.longitude, latitude != 0 || longitude != 0 {
                livePositions[node.id] = TriangulationPosition(latitude: latitude, longitude: longitude)
            }
        }
        let myNodeId = appState.myNodeInfo?.nodeId ?? 0
        if myNodeId != 0, livePositions[myNodeId] == nil, let own = appState.effectiveOwnCoordinate() {
            livePositions[myNodeId] = TriangulationPosition(latitude: own.latitude, longitude: own.longitude)
        }
        let loaded = await TriangulationDataProvider.loadContext(
            livePositions: livePositions,
            names: names,
            myNodeId: myNodeId,
            initialTargetId: initialTargetId,
            database: .shared
        )
        targetId = initialTargetId
        useFittedModel = TriangulationDataProvider.recommendsFitted(loaded.fittedCalibration)
        context = loaded
    }

    private func compute() async {
        guard let context else { return }
        isComputing = true
        defer {
            isComputing = false
            hasComputed = true
        }
        let calibration = useFittedModel && context.fittedCalibration.isFitted
            ? context.fittedCalibration
            : .default
        let result = await TriangulationDataProvider.triangulate(
            targetId: targetId,
            context: context,
            calibration: calibration,
            database: .shared
        )
        guard !Task.isCancelled else { return }
        outcome = result
    }

    private func showOnMap() {
        guard let outcome, let context else { return }
        TriangulationMapStore.shared.show(outcome, targetName: name(outcome.targetId, in: context))
        appState.selectedTab = .map
        dismiss()
        onShownOnMap()
    }

    // MARK: - Formatting

    private func name(_ id: UInt32, in context: TriangulationDataProvider.Context) -> String {
        context.names[id] ?? String(format: "!%08x", id)
    }

    private func coordinateText(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}

/// Default vs. self-calibrated distance model with both parameter sets.
private struct ModelSection: View {
    let calibration: TriangulationService.Calibration
    @Binding var useFittedModel: Bool

    var body: some View {
        Section("Distance model") {
            if calibration.isFitted {
                Picker("Model", selection: $useFittedModel) {
                    Text("Default model").tag(false)
                    Text("Self-calibrated").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            LabeledContent("Default model", value: parameters(.default))
            if calibration.isFitted {
                LabeledContent(
                    "Self-calibrated",
                    value: parameters(calibration)
                        + String(format: String(localized: ", R² = %.2f, σ = %.1f dB, %d links"),
                                 calibration.r2, calibration.sigmaDb, calibration.samples)
                )
                if calibration.clamped {
                    Text("⚠ The fit runs into the physical parameter bounds (degenerate) — its circles would be unusable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(TriangulationDataProvider.recommendsFitted(calibration)
                     ? "Recommendation: self-calibrated (usable distance correlation)."
                     : "Recommendation: default model — the fit has almost no distance correlation (R² < 0.2) and would produce unreliable distances.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Self-calibration needs at least 8 links between nodes with known positions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func parameters(_ calibration: TriangulationService.Calibration) -> String {
        String(
            format: String(localized: "RSSI at 1 km %.1f dBm, n = %.2f"),
            calibration.p1Km,
            calibration.exponent
        )
    }
}

/// One anchor: name, circle radius, evidence.
private struct AnchorRow: View {
    let anchor: TriangulationAnchor

    var body: some View {
        HStack {
            Text(anchor.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if !anchor.isPrior {
                Text(evidenceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(anchor.isPrior
                 ? "±\(TriangulationMapLayer.km(anchor.positionErrorKm)) km"
                 : "\(TriangulationMapLayer.km(anchor.distanceKm)) km")
                .monospacedDigit()
                .frame(minWidth: 60, alignment: .trailing)
        }
    }

    private var evidenceText: String {
        let text: String
        switch anchor.evidence {
        case .rssi: text = String(localized: "RSSI")
        case .snrBothWays: text = String(localized: "SNR both ways")
        case .snrOneWay: text = String(localized: "SNR one way")
        case .reportedPosition: text = ""
        }
        return anchor.noiseFloorDefaulted
            ? text + " · " + String(localized: "default noise floor")
            : text
    }
}
