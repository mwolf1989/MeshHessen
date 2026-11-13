import SwiftUI

/// Edits the telemetry polling plan: which nodes are asked for which telemetry how often.
struct TelemetryPollingSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let nodes: [TelemetryDashboardNode]

    @State private var newNodeId: UInt32?
    @State private var newType: NodeInfoRequestType = .localStats
    @State private var newInterval = 60
    @State private var errorMessage: String?

    private static let intervalChoices = [30, 60, 120, 180, 360, 720, 1_440]

    private var polling: TelemetryPollingService { coordinator.telemetryPolling }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Telemetry Polling")
                    .font(.title2.bold())
                Spacer()
                Toggle("Polling enabled", isOn: Binding(
                    get: { polling.plan.enabled },
                    set: { polling.setEnabled($0) }
                ))
                .toggleStyle(.switch)
            }

            Text("Requests are sent at most once a minute while connected. Up to \(TelemetryPollPlan.maxNodes) nodes; local statistics at most hourly, other telemetry at most every 30 minutes.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            entryList
            addRow

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .alert(
            "Polling",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: newType) { _, type in
            newInterval = max(newInterval, TelemetryPollPlan.minimumIntervalMinutes(for: type))
        }
    }

    @ViewBuilder
    private var entryList: some View {
        if polling.plan.entries.isEmpty {
            ContentUnavailableView(
                "No Polling Entries",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Add a node and a telemetry type below.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(polling.plan.entries) { entry in
                    PollEntryRow(entry: entry, name: name(for: entry.nodeId)) {
                        polling.removeEntry(id: entry.id)
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }

    private var addRow: some View {
        HStack {
            Picker("Node", selection: $newNodeId) {
                Text("Select node").tag(UInt32?.none)
                ForEach(nodes) { node in
                    Text("\(node.name) (\(node.displayID))").tag(Optional(node.id))
                }
            }
            .frame(maxWidth: 240)

            Picker("Type", selection: $newType) {
                ForEach(TelemetryPollPlan.allowedTypes) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)

            Picker("Every", selection: $newInterval) {
                ForEach(intervalChoices(for: newType), id: \.self) { minutes in
                    Text(Self.intervalText(minutes)).tag(minutes)
                }
            }
            .frame(maxWidth: 130)

            Button("Add", systemImage: "plus", action: addEntry)
                .disabled(newNodeId == nil)
        }
    }

    private func intervalChoices(for type: NodeInfoRequestType) -> [Int] {
        let minimum = TelemetryPollPlan.minimumIntervalMinutes(for: type)
        return Self.intervalChoices.filter { $0 >= minimum }
    }

    private func addEntry() {
        guard let newNodeId else { return }
        do {
            try polling.addEntry(nodeId: newNodeId, type: newType, intervalMinutes: newInterval)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func name(for nodeId: UInt32) -> String {
        nodes.first(where: { $0.id == nodeId })?.name ?? TelemetryDashboardNode.fallbackName(for: nodeId)
    }

    static func intervalText(_ minutes: Int) -> String {
        minutes < 60
            ? String(localized: "\(minutes) min")
            : String(localized: "\(minutes / 60) h")
    }
}

private struct PollEntryRow: View {
    let entry: TelemetryPollEntry
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Label(entry.type.displayName, systemImage: entry.type.systemImage)
                .frame(width: 170, alignment: .leading)
            Text(name)
                .lineLimit(1)
            Spacer()
            Text("every \(TelemetryPollingSheet.intervalText(entry.intervalMinutes))")
                .foregroundStyle(.secondary)
            Group {
                if let sent = entry.lastSentUtc {
                    Text(sent, style: .relative)
                } else {
                    Text("never")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 90, alignment: .trailing)
            Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}
