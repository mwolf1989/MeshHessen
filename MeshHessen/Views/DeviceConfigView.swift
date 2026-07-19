import SwiftUI

/// Full device configuration view — tabbed editor for all Meshtastic config categories.
struct DeviceConfigView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = ConfigTab.device
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusMessage: LocalizedStringKey?
    @State private var errorMessage: String?
    @State private var loadedSnapshot: MeshtasticProtocolService.DeviceConfigSnapshot?

    // Config state
    @State private var deviceConfig = Meshtastic_Config.DeviceConfig()
    @State private var positionConfig = Meshtastic_Config.PositionConfig()
    @State private var loraConfig = Meshtastic_Config.LoRaConfig()
    @State private var bluetoothConfig = Meshtastic_Config.BluetoothConfig()
    @State private var networkConfig = Meshtastic_Config.NetworkConfig()
    @State private var displayConfig = Meshtastic_Config.DisplayConfig()
    @State private var powerConfig = Meshtastic_Config.PowerConfig()
    @State private var mqttConfig = Meshtastic_ModuleConfig.MQTTConfig()

    enum ConfigTab: String, CaseIterable, Identifiable {
        case device, position, lora, bluetooth, network, display, power, mqtt
        var id: String { rawValue }

        var label: String {
            switch self {
            case .device:    return "Device"
            case .position:  return "Position"
            case .lora:      return "LoRa"
            case .bluetooth: return "Bluetooth"
            case .network:   return "Network"
            case .display:   return "Display"
            case .power:     return "Power"
            case .mqtt:      return "MQTT"
            }
        }

        var icon: String {
            switch self {
            case .device:    return "cpu"
            case .position:  return "location"
            case .lora:      return "antenna.radiowaves.left.and.right"
            case .bluetooth: return "wave.3.right"
            case .network:   return "wifi"
            case .display:   return "display"
            case .power:     return "bolt.fill"
            case .mqtt:      return "arrow.up.arrow.down"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Device Configuration")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if let status = statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Load from Device") {
                    Task { await loadAllConfigs() }
                }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || !appState.protocolReady)
                Button("Save to Device") {
                    Task { await saveAllConfigs() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isLoading || isSaving || !appState.protocolReady
                            || loadedSnapshot == nil || currentSnapshot == loadedSnapshot
                    )
                Button("Close") { dismiss() }
                    .disabled(isSaving)
            }
            .padding()

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(ConfigTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Config panes
            ScrollView {
                configPane
                    .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            if appState.protocolReady { await loadAllConfigs() }
        }
        .alert(
            "Device Configuration Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var configPane: some View {
        switch selectedTab {
        case .device:    devicePane
        case .position:  positionPane
        case .lora:      loraPane
        case .bluetooth: bluetoothPane
        case .network:   networkPane
        case .display:   displayPane
        case .power:     powerPane
        case .mqtt:      mqttPane
        }
    }

    // MARK: - Device Config

    private var devicePane: some View {
        Form {
            Section("Device Role") {
                Picker("Role", selection: $deviceConfig.role) {
                    ForEach(DeviceRole.allCases) { role in
                        Text(role.name).tag(Meshtastic_Config.DeviceConfig.Role(rawValue: role.rawValue) ?? .client)
                    }
                }
                Text(DeviceRole(rawValue: deviceConfig.role.rawValue)?.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Serial") {
                Toggle("Serial Console Enabled", isOn: $deviceConfig.serialEnabled)
            }

            Section("Behavior") {
                Picker("Rebroadcast Mode", selection: $deviceConfig.rebroadcastMode) {
                    ForEach(RebroadcastMode.allCases) { mode in
                        Text(mode.name).tag(Meshtastic_Config.DeviceConfig.RebroadcastMode(rawValue: mode.rawValue) ?? .all)
                    }
                }
                HStack {
                    Text("Node Info Broadcast (secs)")
                    Spacer()
                    TextField("", value: $deviceConfig.nodeInfoBroadcastSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Node Info Broadcast (secs)")
                }
                Toggle("Double Tap as Button Press", isOn: $deviceConfig.doubleTapAsButtonPress)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Position Config

    private var positionPane: some View {
        Form {
            Section("Broadcasting") {
                HStack {
                    Text("Broadcast Interval (secs)")
                    Spacer()
                    TextField("", value: $positionConfig.positionBroadcastSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Broadcast Interval (secs)")
                }
                Toggle("Smart Position Enabled", isOn: $positionConfig.positionBroadcastSmartEnabled)
            }

            Section("GPS") {
                HStack {
                    Text("GPS Update Interval (secs)")
                    Spacer()
                    TextField("", value: $positionConfig.gpsUpdateInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("GPS Update Interval (secs)")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - LoRa Config

    private var loraPane: some View {
        Form {
            Section("Region & Preset") {
                Picker("Region", selection: $loraConfig.region) {
                    ForEach(RegionCode.allCases) { region in
                        Text(region.name).tag(Meshtastic_Config.LoRaConfig.RegionCode(rawValue: region.rawValue) ?? .unset)
                    }
                }
                Toggle("Use Preset", isOn: $loraConfig.usePreset)
                if loraConfig.usePreset {
                    Picker("Modem Preset", selection: $loraConfig.modemPreset) {
                        ForEach(ModemPreset.allCases) { preset in
                            Text(preset.name).tag(Meshtastic_Config.LoRaConfig.ModemPreset(rawValue: preset.rawValue) ?? .longFast)
                        }
                    }
                }
            }

            Section("Radio") {
                HStack {
                    Text("Hop Limit")
                    Spacer()
                    TextField("", value: $loraConfig.hopLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .accessibilityLabel("Hop Limit")
                }
                Toggle("TX Enabled", isOn: $loraConfig.txEnabled)
                HStack {
                    Text("TX Power (dBm)")
                    Spacer()
                    TextField("", value: $loraConfig.txPower, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .accessibilityLabel("TX Power (dBm)")
                }
                Toggle("Override Duty Cycle", isOn: $loraConfig.overrideDutyCycle)
            }

            if !loraConfig.usePreset {
                Section("Advanced") {
                    HStack {
                        Text("Bandwidth")
                        Spacer()
                        TextField("", value: $loraConfig.bandwidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityLabel("Bandwidth")
                    }
                    HStack {
                        Text("Spread Factor")
                        Spacer()
                        TextField("", value: $loraConfig.spreadFactor, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityLabel("Spread Factor")
                    }
                    HStack {
                        Text("Coding Rate")
                        Spacer()
                        TextField("", value: $loraConfig.codingRate, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityLabel("Coding Rate")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bluetooth Config

    private var bluetoothPane: some View {
        Form {
            Section("Bluetooth") {
                Toggle("Bluetooth Enabled", isOn: $bluetoothConfig.enabled)
                Picker("Pairing Mode", selection: $bluetoothConfig.mode) {
                    ForEach(BluetoothMode.allCases) { mode in
                        Text(mode.name).tag(Meshtastic_Config.BluetoothConfig.PairingMode(rawValue: mode.rawValue) ?? .randomPin)
                    }
                }
                if bluetoothConfig.mode == .fixedPin {
                    HStack {
                        Text("Fixed PIN")
                        Spacer()
                        TextField("", value: $bluetoothConfig.fixedPin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityLabel("Fixed PIN")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Network Config

    private var networkPane: some View {
        Form {
            Section("WiFi") {
                Toggle("WiFi Enabled", isOn: $networkConfig.wifiEnabled)
                if networkConfig.wifiEnabled {
                    HStack {
                        Text("SSID")
                        Spacer()
                        TextField("NetworkName", text: $networkConfig.wifiSsid)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("Password", text: $networkConfig.wifiPsk)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
            }

            Section("NTP") {
                HStack {
                    Text("NTP Server")
                    Spacer()
                    TextField("0.pool.ntp.org", text: $networkConfig.ntpServer)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Display Config

    private var displayPane: some View {
        Form {
            Section("Screen") {
                HStack {
                    Text("Screen On Time (secs)")
                    Spacer()
                    TextField("", value: $displayConfig.screenOnSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Screen On Time (secs)")
                }
                HStack {
                    Text("Auto Carousel (secs, 0=off)")
                    Spacer()
                    TextField("", value: $displayConfig.autoScreenCarouselSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Auto Carousel (secs, 0=off)")
                }
                Toggle("Compass North Top", isOn: $displayConfig.compassNorthTop)
                Toggle("Flip Screen", isOn: $displayConfig.flipScreen)
            }

            Section("GPS Display") {
                Picker("GPS Format (deprecated)", selection: $displayConfig.gpsFormat) {
                    Text("Default").tag(Meshtastic_Config.DisplayConfig.DeprecatedGpsCoordinateFormat.unused)
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Power Config

    private var powerPane: some View {
        Form {
            Section("Power Saving") {
                Toggle("Power Saving Mode", isOn: $powerConfig.isPowerSaving)
                HStack {
                    Text("Shutdown After (secs, on battery)")
                    Spacer()
                    TextField("", value: $powerConfig.onBatteryShutdownAfterSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Shutdown After (secs, on battery)")
                }
            }

            Section("Sleep Timers") {
                HStack {
                    Text("Wait Bluetooth (secs)")
                    Spacer()
                    TextField("", value: $powerConfig.waitBluetoothSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Wait Bluetooth (secs)")
                }
                HStack {
                    Text("Super Deep Sleep (secs)")
                    Spacer()
                    TextField("", value: $powerConfig.sdsSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Super Deep Sleep (secs)")
                }
                HStack {
                    Text("Light Sleep (secs)")
                    Spacer()
                    TextField("", value: $powerConfig.lsSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Light Sleep (secs)")
                }
                HStack {
                    Text("Min Wake (secs)")
                    Spacer()
                    TextField("", value: $powerConfig.minWakeSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Min Wake (secs)")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - MQTT Config

    private var mqttPane: some View {
        Form {
            Section("MQTT") {
                Toggle("MQTT Enabled", isOn: $mqttConfig.enabled)
                if mqttConfig.enabled {
                    HStack {
                        Text("Server Address")
                        Spacer()
                        TextField("mqtt.meshtastic.org", text: $mqttConfig.address)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    HStack {
                        Text("Username")
                        Spacer()
                        TextField("meshdev", text: $mqttConfig.username)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("Password", text: $mqttConfig.password)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                    Toggle("Encryption Enabled", isOn: $mqttConfig.encryptionEnabled)
                    Toggle("JSON Enabled", isOn: $mqttConfig.jsonEnabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Load / Save

    private func loadAllConfigs() async {
        isLoading = true
        statusMessage = "Loading config…"
        errorMessage = nil
        defer { isLoading = false }
        do {
            let snapshot = try await coordinator.requestDeviceConfig()
            apply(snapshot)
            loadedSnapshot = snapshot
            statusMessage = "Config loaded"
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            loadedSnapshot = nil
            statusMessage = "Load failed"
            errorMessage = error.localizedDescription
        }
    }

    private func saveAllConfigs() async {
        guard let loadedSnapshot else {
            errorMessage = String(localized: "Load the complete configuration before saving.")
            return
        }
        isSaving = true
        statusMessage = "Saving config…"
        errorMessage = nil
        defer { isSaving = false }
        do {
            let snapshot = currentSnapshot
            let didSave = try await coordinator.saveDeviceConfig(snapshot, replacing: loadedSnapshot)
            self.loadedSnapshot = snapshot
            statusMessage = didSave ? "Config saved and verified" : "No changes"
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            statusMessage = "Save failed"
            errorMessage = error.localizedDescription
        }
    }

    private var currentSnapshot: MeshtasticProtocolService.DeviceConfigSnapshot {
        MeshtasticProtocolService.DeviceConfigSnapshot(
            device: deviceConfig,
            position: positionConfig,
            lora: loraConfig,
            bluetooth: bluetoothConfig,
            network: networkConfig,
            display: displayConfig,
            power: powerConfig,
            mqtt: mqttConfig
        )
    }

    private func apply(_ snapshot: MeshtasticProtocolService.DeviceConfigSnapshot) {
        deviceConfig = snapshot.device
        positionConfig = snapshot.position
        loraConfig = snapshot.lora
        bluetoothConfig = snapshot.bluetooth
        networkConfig = snapshot.network
        displayConfig = snapshot.display
        powerConfig = snapshot.power
        mqttConfig = snapshot.mqtt
    }
}
