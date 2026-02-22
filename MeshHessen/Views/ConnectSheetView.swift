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
    @State private var bluetoothName = ""
    @State private var availablePorts: [String] = []
    @State private var isConnecting = false
    @State private var errorMessage: String?

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
                .disabled(isConnecting)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { loadDefaults() }
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
            Text("Bluetooth Device Name")
                .font(.headline)
            TextField("e.g. Meshtastic_1234 or T-Deck", text: $bluetoothName)
                .textFieldStyle(.roundedBorder)
            Text("The app will scan for a device whose name contains the text above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            params = .bluetooth(deviceAddress: bluetoothName, deviceName: bluetoothName)
            AppLogger.shared.log("[UI] Connecting via Bluetooth: \(bluetoothName)", debug: true)
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
