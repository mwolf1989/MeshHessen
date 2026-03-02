import SwiftUI
import MapKit

/// Sheet showing traceroute results for a node, with hop table and map visualization.
struct TracerouteSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let targetNodeId: UInt32
    let targetName: String

    @State private var isRequesting = false
    @State private var results: [TracerouteResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
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
                Button {
                    isRequesting = true
                    Task {
                        await coordinator.sendTraceroute(to: targetNodeId)
                        // Wait a bit then refresh results
                        try? await Task.sleep(for: .seconds(2))
                        results = coordinator.tracerouteResults.filter { $0.targetNodeId == targetNodeId }
                        isRequesting = false
                    }
                } label: {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run Traceroute", systemImage: "arrow.triangle.swap")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    "No Traceroute Results",
                    systemImage: "arrow.triangle.swap",
                    description: Text("Run a traceroute to see the network path to this node.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(results) { result in
                            TracerouteResultCard(result: result)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            results = coordinator.tracerouteResults.filter { $0.targetNodeId == targetNodeId }
            if results.isEmpty {
                results = TracerouteStore.shared.loadAll().filter { $0.targetNodeId == targetNodeId }
            }
        }
    }
}

/// Card showing a single traceroute result
private struct TracerouteResultCard: View {
    let result: TracerouteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.requestTime, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rtt = result.roundTripMs {
                    Text("RTT: \(rtt) ms")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Text("\(result.hops.count) hop(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Hop table
            ForEach(Array(result.hops.enumerated()), id: \.element.id) { index, hop in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)

                    if hop.viaMqtt {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text(hop.nodeName)
                        .font(.callout)
                        .fontWeight(.medium)

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
                .padding(.vertical, 2)

                if index < result.hops.count - 1 {
                    HStack {
                        Spacer().frame(width: 20)
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func snrColor(_ snr: Float) -> Color {
        if snr >= 5 { return .green }
        if snr >= 0 { return .orange }
        return .red
    }
}
