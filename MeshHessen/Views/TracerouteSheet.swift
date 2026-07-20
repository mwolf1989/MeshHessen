import SwiftUI
import MapKit

/// Sheet showing traceroute results for a node, with hop table and map visualization.
struct TracerouteSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let targetNodeId: UInt32
    let targetName: String

    @State private var isRequesting = false
    @State private var requestStartedAt: Date?
    @State private var requestTask: Task<Void, Never>?
    @State private var statusMessage: LocalizedStringKey?

    private var results: [TracerouteResult] {
        coordinator.protocol_.tracerouteResults.filter { $0.targetNodeId == targetNodeId }
    }

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
                    runTraceroute()
                } label: {
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

                Button("Done") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onChange(of: results.first?.id) {
            guard let requestStartedAt,
                  let responseTime = results.first?.responseTime,
                  responseTime >= requestStartedAt
            else { return }

            requestTask?.cancel()
            requestTask = nil
            self.requestStartedAt = nil
            isRequesting = false
            statusMessage = "Traceroute completed"
        }
        .onDisappear {
            requestTask?.cancel()
        }
    }

    private func runTraceroute() {
        requestTask?.cancel()
        let startedAt = Date()
        requestStartedAt = startedAt
        isRequesting = true
        statusMessage = "Waiting for traceroute response…"

        requestTask = Task {
            let wasSent = await coordinator.sendTraceroute(to: targetNodeId)
            guard wasSent else {
                requestStartedAt = nil
                isRequesting = false
                statusMessage = "Traceroute could not be sent"
                return
            }

            do {
                try await Task.sleep(for: .seconds(30))
                guard requestStartedAt == startedAt else { return }
                requestStartedAt = nil
                isRequesting = false
                statusMessage = "No traceroute response received"
            } catch {
                // A new result or dismissal cancels the timeout task.
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
                Text(localizedHopCount(result.hops.count))
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
