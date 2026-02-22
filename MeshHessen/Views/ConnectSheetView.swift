import SwiftUI
import AppKit

/// Connection type picker + parameter fields + Connect button
struct ConnectSheetView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: ConnectionType = .tcp
    @State private var serialPort = ""
    @State private var tcpHost = ""
    @State private var tcpPort = ""
    @State private var availablePorts: [String] = []
    @State private var isConnecting = false
    @State private var errorMessage: String?
    // BLE scanner state
    @State private var selectedBLEDevice: DiscoveredBLEDevice?
    @State private var isBleScanActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to Device")
                .font(.title2.bold())

            // Connection type picker
            Picker("Connection Type", selection: $selectedType) {
                ForEach(ConnectionType.allCases) { type in
                    Text(type.localizedName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Type-specific parameters
            Group {
                switch selectedType {
                case .serial:
                    serialFields
                case .bluetooth:
                    bluetoothFields
                case .tcp:
                    tcpFields
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: selectedType)

            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.escape)

                Button(isConnecting ? "Connecting…" : "Connect") {
                    Task { await connect() }
                }
                .keyboardShortcut(.return)
                .disabled(isConnecting || (selectedType == .bluetooth && selectedBLEDevice == nil))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { loadDefaults() }
        .onChange(of: selectedType) { _, newType in
            // Auto-stop BLE scan when switching away from Bluetooth tab
            if newType != .bluetooth && isBleScanActive {
                coordinator.stopBLEScanning()
                isBleScanActive = false
            }
        }
        .onDisappear {
            if isBleScanActive {
                coordinator.stopBLEScanning()
                isBleScanActive = false
            }
        }
    }

    // MARK: - Field groups

    private var serialFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Serial Port")
                .font(.headline)
            HStack {
                Picker("Port", selection: $serialPort) {
                    ForEach(availablePorts, id: \.self) { port in
                        Text(port).tag(port)
                    }
                }
                .labelsHidden()

                Button {
                    availablePorts = SerialConnectionService.availablePorts
                    AppLogger.shared.log("[UI] Refreshed serial ports: \(availablePorts.count) found", debug: true)
                    if !availablePorts.contains(serialPort) {
                        serialPort = availablePorts.first ?? ""
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh port list")
            }
            Text("Baud rate: 115200, 8N1")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var bluetoothFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth Device")
                .font(.headline)

            if coordinator.discoveredBLEDevices.isEmpty {
                ContentUnavailableView {
                    Label(isBleScanActive ? "Scanning…" : "No Devices", systemImage: isBleScanActive ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                } description: {
                    Text(isBleScanActive
                         ? "Searching for nearby Meshtastic nodes via Bluetooth."
                         : "Press \"Scan\" to search for nearby Meshtastic nodes.")
                }
                .frame(height: 100)
            } else {
                List(coordinator.discoveredBLEDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .fontWeight(selectedBLEDevice?.id == device.id ? .bold : .regular)
                            Text(device.id.uuidString.prefix(18) + "…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(rssiColor(device.rssi))
                        if selectedBLEDevice?.id == device.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBLEDevice = device }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 176)
            }

            HStack {
                Button(isBleScanActive ? "Stop Scan" : "Scan for Devices") {
                    if isBleScanActive {
                        coordinator.stopBLEScanning()
                        isBleScanActive = false
                    } else {
                        selectedBLEDevice = nil
                        coordinator.startBLEScanning()
                        isBleScanActive = true
                    }
                }
                .buttonStyle(.bordered)

                if let dev = selectedBLEDevice {
                    Spacer()
                    Label(dev.name, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            Text("Make sure Bluetooth is enabled and the Meshtastic node is powered on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi > -60 { return .green }
        if rssi > -80 { return .orange }
        return .red
    }

    private var tcpFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TCP / WiFi")
                .font(.headline)
            HStack {
                TextField("Host (e.g. 192.168.1.1)", text: $tcpHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $tcpPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
        }
    }

    // MARK: - Actions

    private func loadDefaults() {
        let settings = SettingsService.shared
        tcpHost = settings.lastTcpHost
        tcpPort = String(settings.lastTcpPort)
        availablePorts = SerialConnectionService.availablePorts
        serialPort = settings.lastComPort.isEmpty ? (availablePorts.first ?? "") : settings.lastComPort
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil

        // Save last used
        let settings = SettingsService.shared

        let params: ConnectionParameters
        switch selectedType {
        case .serial:
            settings.lastComPort = serialPort
            params = .serial(portName: serialPort)
            AppLogger.shared.log("[UI] Connecting via Serial: \(serialPort)", debug: true)
        case .bluetooth:
            guard let device = selectedBLEDevice else {
                errorMessage = String(localized: "Please select a Bluetooth device from the list. Press \"Scan\" to search.")
                isConnecting = false
                return
            }
            // Stop scanning before connecting
            if isBleScanActive {
                coordinator.stopBLEScanning()
                isBleScanActive = false
            }
            params = .bluetooth(deviceAddress: device.id.uuidString, deviceName: device.name)
            AppLogger.shared.log("[UI] Connecting via Bluetooth: \(device.name) (\(device.id))", debug: true)
        case .tcp:
            let port = Int(tcpPort) ?? 4403
            settings.lastTcpHost = tcpHost
            settings.lastTcpPort = port
            params = .tcp(hostname: tcpHost, port: port)
            AppLogger.shared.log("[UI] Connecting via TCP: \(tcpHost):\(port)", debug: true)
        }

        await coordinator.connect(type: selectedType, parameters: params)

        isConnecting = false
        if case .error(let e) = appState.connectionState {
            AppLogger.shared.log("[UI] Connection failed: \(e)", debug: true)
            errorMessage = e
        } else if appState.connectionState.isConnected {
            AppLogger.shared.log("[UI] Transport connected; protocol sync continues in background", debug: true)
            dismiss()
        } else {
            let message = appState.protocolStatusMessage ?? String(localized: "Connection still in progress…")
            AppLogger.shared.log("[UI] Connection status unresolved: \(message)", debug: true)
            errorMessage = message
        }
    }
}

#Preview {
    ConnectSheetView()
        .environment(\.appState, AppState())
        .environment(AppCoordinator())
}
