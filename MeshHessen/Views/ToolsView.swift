import SwiftUI

/// Operational tools that need live coordinator state rather than static
/// preferences. This mirrors the Windows Tools tab while remaining a native
/// macOS sheet.
struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var settings = SettingsService.shared
    @State private var showTDeckWizard = false
    @State private var showTileExport = false

    var body: some View {
        NavigationStack {
            Form {
                virtualNodeSection
                mqttProxySection
                tDeckSection
            }
            .formStyle(.grouped)
            .navigationTitle("Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .sheet(isPresented: $showTDeckWizard) {
            TDeckWizardView()
        }
        .sheet(isPresented: $showTileExport) {
            TDeckWizardView(startAtExport: true)
        }
        .onChange(of: settings.virtualNodeEnabled) { _, _ in applySettings() }
        .onChange(of: settings.virtualNodePort) { _, _ in applySettings() }
        .onChange(of: settings.virtualNodeBlockAdmin) { _, _ in applySettings() }
    }

    private var virtualNodeSection: some View {
        Section {
            Toggle("Enable Virtual Node TCP server", isOn: $settings.virtualNodeEnabled)

            LabeledContent("TCP port") {
                TextField("4404", value: $settings.virtualNodePort, format: .number)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                    .disabled(!settings.virtualNodeEnabled)
            }

            Toggle("Block admin commands from clients", isOn: $settings.virtualNodeBlockAdmin)
                .disabled(!settings.virtualNodeEnabled)

            LabeledContent("Status") {
                Label(virtualNodeStatusText, systemImage: virtualNodeStatusSymbol)
                    .foregroundStyle(virtualNodeStatusColor)
            }

            if let error = coordinator.virtualNodeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if coordinator.virtualNodeClients.isEmpty {
                Text("No Meshtastic clients are currently connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.virtualNodeClients) { client in
                    LabeledContent(client.endpoint) {
                        Text(client.connectedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }

            Button("Apply / Restart Server") {
                applySettings()
            }
            .disabled(!appState.connectionState.isConnected)
        } header: {
            Text("Virtual Node")
        } footer: {
            Text("Meshtastic apps can connect to this Mac on the configured TCP port. Configuration replay, bidirectional forwarding, multiple clients and kiosk admin blocking are supported.")
        }
    }

    private var mqttProxySection: some View {
        Section("MQTT Proxy") {
            LabeledContent("Status") {
                Label(mqttStatusText, systemImage: mqttStatusSymbol)
                    .foregroundStyle(mqttStatusColor)
            }
            Text("The proxy follows the MQTT module configuration of the connected radio and is active only when proxy-to-client mode is enabled on that radio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var tDeckSection: some View {
        Section("T-Deck Map Assistant") {
            Button {
                showTDeckWizard = true
            } label: {
                Label("Prepare SD Card…", systemImage: "sdcard")
            }
            Button {
                showTileExport = true
            } label: {
                Label("Export Local Tile Cache as ZIP…", systemImage: "shippingbox")
            }
            Text("Guided region, zoom, map-style and additive transfer workflow for T-Deck-compatible offline maps.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var virtualNodeStatusText: String {
        if let error = coordinator.virtualNodeError, !error.isEmpty {
            return String(localized: "Error")
        }
        if settings.virtualNodeEnabled, appState.connectionState.isConnected {
            let count = coordinator.virtualNodeClients.count
            return String(localized: "Running on port \(settings.virtualNodePort) · \(count) client(s)")
        }
        if settings.virtualNodeEnabled {
            return String(localized: "Waiting for a physical node connection")
        }
        return String(localized: "Stopped")
    }

    private var virtualNodeStatusSymbol: String {
        if coordinator.virtualNodeError != nil { return "exclamationmark.triangle.fill" }
        if settings.virtualNodeEnabled, appState.connectionState.isConnected { return "network" }
        return "stop.circle"
    }

    private var virtualNodeStatusColor: Color {
        if coordinator.virtualNodeError != nil { return .red }
        if settings.virtualNodeEnabled, appState.connectionState.isConnected { return .green }
        return .secondary
    }

    private var mqttStatusText: String {
        switch coordinator.mqttProxyState {
        case .stopped:
            return String(localized: "Stopped")
        case .connecting(let host, let port):
            return String(localized: "Connecting to \(host):\(port)")
        case .connected(let host, let port, _):
            return String(localized: "Connected to \(host):\(port)")
        case .waitingToReconnect(let reason):
            return String(localized: "Waiting to reconnect: \(reason)")
        }
    }

    private var mqttStatusSymbol: String {
        switch coordinator.mqttProxyState {
        case .connected: return "cloud.fill"
        case .connecting, .waitingToReconnect: return "arrow.triangle.2.circlepath"
        case .stopped: return "cloud.slash"
        }
    }

    private var mqttStatusColor: Color {
        switch coordinator.mqttProxyState {
        case .connected: return .green
        case .connecting: return .yellow
        case .waitingToReconnect: return .orange
        case .stopped: return .secondary
        }
    }

    private func applySettings() {
        Task { await coordinator.applyAuxiliaryServiceSettings() }
    }
}
