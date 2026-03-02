import SwiftUI

/// Full device configuration view — tabbed editor for all Meshtastic config categories.
struct DeviceConfigView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = ConfigTab.device
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusMessage: String?

    // Config state
    @State private var deviceConfig = Meshtastic_DeviceConfig()
    @State private var positionConfig = Meshtastic_PositionConfig()
    @State private var loraConfig = Meshtastic_LoRaConfig()
    @State private var bluetoothConfig = Meshtastic_BluetoothConfig()
    @State private var networkConfig = Meshtastic_NetworkConfig()
    @State private var displayConfig = Meshtastic_DisplayConfig()
    @State private var powerConfig = Meshtastic_PowerConfig()
    @State private var mqttConfig = Meshtastic_MQTTConfig()

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
                Button("Load from Device") { loadAllConfigs() }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || !appState.protocolReady)
                Button("Save to Device") { saveAllConfigs() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !appState.protocolReady)
                Button("Close") { dismiss() }
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
        .onAppear {
            if appState.protocolReady { loadAllConfigs() }
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
                        Text(role.name).tag(Meshtastic_Role(rawValue: role.rawValue) ?? .client)
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
                        Text(mode.name).tag(UInt32(mode.rawValue))
                    }
                }
                HStack {
                    Text("Node Info Broadcast (secs)")
                    Spacer()
                    TextField("900", value: $deviceConfig.nodeInfoBroadcastSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
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
                    TextField("900", value: $positionConfig.positionBroadcastSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Toggle("Smart Position Enabled", isOn: $positionConfig.positionBroadcastSmartEnabled)
            }

            Section("GPS") {
                HStack {
                    Text("GPS Update Interval (secs)")
                    Spacer()
                    TextField("120", value: $positionConfig.gpsUpdateInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
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
                        Text(region.name).tag(Meshtastic_Region(rawValue: region.rawValue) ?? .unsetRegion)
                    }
                }
                Toggle("Use Preset", isOn: $loraConfig.usePreset)
                if loraConfig.usePreset {
                    Picker("Modem Preset", selection: $loraConfig.modemPreset) {
                        ForEach(ModemPreset.allCases) { preset in
                            Text(preset.name).tag(Meshtastic_ModemPreset(rawValue: preset.rawValue) ?? .longFast)
                        }
                    }
                }
            }

            Section("Radio") {
                HStack {
                    Text("Hop Limit")
                    Spacer()
                    TextField("3", value: $loraConfig.hopLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                Toggle("TX Enabled", isOn: $loraConfig.txEnabled)
                HStack {
                    Text("TX Power (dBm)")
                    Spacer()
                    TextField("0", value: $loraConfig.txPower, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                Toggle("Override Duty Cycle", isOn: $loraConfig.overrideDutyCycle)
            }

            if !loraConfig.usePreset {
                Section("Advanced") {
                    HStack {
                        Text("Bandwidth")
                        Spacer()
                        TextField("0", value: $loraConfig.bandwidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Spread Factor")
                        Spacer()
                        TextField("0", value: $loraConfig.spreadFactor, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Coding Rate")
                        Spacer()
                        TextField("0", value: $loraConfig.codingRate, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
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
                        Text(mode.name).tag(UInt32(mode.rawValue))
                    }
                }
                if bluetoothConfig.mode == 1 { // Fixed PIN
                    HStack {
                        Text("Fixed PIN")
                        Spacer()
                        TextField("123456", value: $bluetoothConfig.fixedPin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
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
                    TextField("60", value: $displayConfig.screenOnSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Toggle("Auto Screen Carousel", isOn: $displayConfig.autoScreenCarouselSecs)
                Toggle("Compass North Top", isOn: $displayConfig.compassNorthTop)
                Toggle("Flip Screen", isOn: $displayConfig.flipScreen)
            }

            Section("GPS Display") {
                Picker("GPS Format", selection: $displayConfig.gpsFormat) {
                    Text("Decimal").tag(Meshtastic_GpsCoordinateFormat.dec)
                    Text("DMS").tag(Meshtastic_GpsCoordinateFormat.dms)
                }
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
                    TextField("0", value: $powerConfig.onBatteryShutdownAfterSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("Sleep Timers") {
                HStack {
                    Text("Wait Bluetooth (secs)")
                    Spacer()
                    TextField("60", value: $powerConfig.waitBluetoothSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                HStack {
                    Text("Super Deep Sleep (secs)")
                    Spacer()
                    TextField("0", value: $powerConfig.sdsSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                HStack {
                    Text("Light Sleep (secs)")
                    Spacer()
                    TextField("300", value: $powerConfig.lsSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                HStack {
                    Text("Min Wake (secs)")
                    Spacer()
                    TextField("10", value: $powerConfig.minWakeSecs, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
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

    private func loadAllConfigs() {
        isLoading = true
        statusMessage = "Loading config…"
        Task {
            await coordinator.requestDeviceConfig()
            // Wait for responses
            try? await Task.sleep(for: .seconds(3))
            // Read config from protocol service
            let proto = coordinator.protocol_
            if let config = proto.receivedConfigs[.device] {
                deviceConfig = config.device
            }
            if let config = proto.receivedConfigs[.position] {
                positionConfig = config.position
            }
            if let config = proto.receivedConfigs[.lora] {
                loraConfig = config.lora
            }
            if let config = proto.receivedConfigs[.bluetooth] {
                bluetoothConfig = config.bluetooth
            }
            if let config = proto.receivedConfigs[.network] {
                networkConfig = config.network
            }
            if let config = proto.receivedConfigs[.display] {
                displayConfig = config.display
            }
            if let config = proto.receivedConfigs[.power] {
                powerConfig = config.power
            }
            if let moduleConfig = proto.receivedModuleConfigs["mqtt"] {
                mqttConfig = moduleConfig.mqtt
            }
            isLoading = false
            statusMessage = "Config loaded"
        }
    }

    private func saveAllConfigs() {
        isSaving = true
        statusMessage = "Saving config…"
        Task {
            await coordinator.saveDeviceConfig(
                device: deviceConfig,
                position: positionConfig,
                lora: loraConfig,
                bluetooth: bluetoothConfig,
                network: networkConfig,
                display: displayConfig,
                power: powerConfig,
                mqtt: mqttConfig
            )
            isSaving = false
            statusMessage = "Config saved — device may reboot"
        }
    }
}
