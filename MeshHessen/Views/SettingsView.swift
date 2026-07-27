import AppKit
import SwiftUI

/// macOS Settings window (⌘,) with the system-wide feature-parity settings.
struct SettingsView: View {
    @State private var selectedTab = SettingsTab.general
    @State private var settings = SettingsService.shared
    @State private var kioskState = KioskState.shared

    var body: some View {
        if kioskState.isFeatureLocked(.settings) {
            KioskUnlockSettingsPane(kioskState: kioskState)
                .frame(width: 720, height: 640)
        } else {
            TabView(selection: $selectedTab) {
            GeneralSettingsPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ConnectionSettingsPane(settings: settings)
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(SettingsTab.connection)

            MapSettingsPane(settings: settings)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(SettingsTab.map)

            DataSettingsPane(settings: settings)
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag(SettingsTab.data)

            KioskSettingsPane(settings: settings, kioskState: kioskState)
                .tabItem { Label("Kiosk", systemImage: "lock.shield") }
                .tag(SettingsTab.kiosk)

            NotificationSettingsPane(settings: settings)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)

            DebugSettingsPane(settings: settings)
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(SettingsTab.debug)
            }
            .frame(width: 720, height: 640)
        }
    }
}

private struct KioskUnlockSettingsPane: View {
    @Bindable var kioskState: KioskState
    @State private var password = ""
    @State private var isUnlocking = false

    var body: some View {
        ContentUnavailableView {
            Label("Settings Locked", systemImage: "lock.shield.fill")
        } description: {
            Text("Enter the kiosk password to unlock protected settings.")
        } actions: {
            VStack(spacing: 10) {
                SecureField("Kiosk password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isUnlocking)
                if let errorMessage = kioskState.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        isUnlocking = true
        Task {
            _ = await kioskState.unlock(with: password)
            password = ""
            isUnlocking = false
        }
    }
}

private enum SettingsTab {
    case general
    case connection
    case map
    case data
    case kiosk
    case notifications
    case debug
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsService
    @State private var updateStatus = UpdateStatus.idle

    var body: some View {
        Form {
            Section("Application") {
                Picker("Language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.localizedName).tag(language)
                    }
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.localizedName).tag(appearance)
                    }
                }
            }

            Section("Identity") {
                TextField("Station Name", text: $settings.stationName)
                    .textFieldStyle(.roundedBorder)
                    .help("Your station name shown to other nodes")
            }

            Section("Text Size") {
                HStack {
                    Button(action: decreaseTextSize) {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.fontSizeStep <= -3)
                    .help("Smaller text (⌘-)")

                    Spacer()
                    Text(fontSizeLabel)
                        .monospacedDigit()
                    Spacer()

                    Button(action: increaseTextSize) {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.bordered)
                    .disabled(settings.fontSizeStep >= 3)
                    .help("Larger text (⌘+)")
                }
                Button("Reset to default", action: resetTextSize)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .disabled(settings.fontSizeStep == 0)
            }

            Section("Nodes") {
                Toggle("Use tile view", isOn: $settings.fancyNodeListEnabled)
                Toggle("Color tiles by signal quality", isOn: $settings.colorfulNodeListEnabled)
                    .disabled(!settings.fancyNodeListEnabled)
            }

            Section("Updates") {
                HStack {
                    Button("Check for updates", action: checkForUpdates)
                        .disabled(updateStatus.isChecking)
                    if updateStatus.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    updateStatusView
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateStatus {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…")
                .foregroundStyle(.secondary)
        case .current:
            Text("No newer stable release found")
                .foregroundStyle(.secondary)
        case .available(let update):
            Button("Version \(update.version.description) available") {
                NSWorkspace.shared.open(update.releaseURL)
            }
            .buttonStyle(.link)
        }
    }

    private var fontSizeLabel: String {
        switch settings.fontSizeStep {
        case -3: return "XS"
        case -2: return "S"
        case -1: return "M"
        case 0: return String(localized: "Default")
        case 1: return "L"
        case 2: return "XL"
        default: return "XXL"
        }
    }

    private func decreaseTextSize() {
        settings.fontSizeStep -= 1
    }

    private func increaseTextSize() {
        settings.fontSizeStep += 1
    }

    private func resetTextSize() {
        settings.fontSizeStep = 0
    }

    private func checkForUpdates() {
        updateStatus = .checking
        Task {
            if let update = await UpdateChecker.shared.checkForUpdate() {
                updateStatus = .available(update)
            } else {
                updateStatus = .current
            }
        }
    }

    private enum UpdateStatus {
        case idle
        case checking
        case current
        case available(UpdateAvailability)

        var isChecking: Bool {
            if case .checking = self { return true }
            return false
        }
    }
}

// MARK: - Connection

private struct ConnectionSettingsPane: View {
    @Bindable var settings: SettingsService

    var body: some View {
        Form {
            Section("Last Used Connection") {
                Picker("Transport", selection: $settings.lastConnectionType) {
                    ForEach(ConnectionType.allCases) { type in
                        Text(type.localizedName).tag(type)
                    }
                }

                LabeledContent("Serial port") {
                    TextField("/dev/cu.usbserial", text: $settings.lastComPort)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("TCP host") {
                    HStack {
                        TextField("192.168.1.1", text: $settings.lastTcpHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", value: $settings.lastTcpPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                LabeledContent("Bluetooth device") {
                    TextField("Device name", text: $settings.lastBluetoothDeviceName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Time Synchronization") {
                Toggle("Synchronize time after connecting", isOn: $settings.autoTimeSyncOnConnect)
                LabeledContent("Drift threshold in seconds") {
                    TextField(
                        "300",
                        value: $settings.timeSyncDriftThresholdSeconds,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                }
                Text("Use 0 to disable drift correction; other values are limited to at least 60 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Administration") {
                Stepper(
                    "Request timeout: \(settings.remoteAdminTimeoutSeconds) seconds",
                    value: $settings.remoteAdminTimeoutSeconds,
                    in: 5...120,
                    step: 5
                )
            }

            Section("Virtual Node") {
                Toggle("Enable Virtual Node server", isOn: $settings.virtualNodeEnabled)
                LabeledContent("TCP port") {
                    TextField("4404", value: $settings.virtualNodePort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Toggle("Block admin commands from clients", isOn: $settings.virtualNodeBlockAdmin)
                if settings.kioskModeEnabled {
                    Text("Admin commands are always blocked while kiosk mode is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Map

private struct MapSettingsPane: View {
    @Bindable var settings: SettingsService

    var body: some View {
        Form {
            Section("Map Rendering") {
                Picker("Renderer", selection: $settings.mapRenderMode) {
                    ForEach(MapRenderMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.mapMode == .publicOpenStreetMap)

                Picker("Mode", selection: $settings.mapMode) {
                    ForEach(MapMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }

                Picker("Style", selection: $settings.meshMapStyle) {
                    ForEach(MeshMapStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .disabled(settings.mapMode == .publicOpenStreetMap)

                if settings.mapMode == .publicOpenStreetMap {
                    Label(
                        "Public OSM permits interactive raster use only; bulk downloads are disabled.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Raster Tile URLs") {
                URLSettingField(title: "OSM", text: $settings.osmTileURL)
                URLSettingField(title: "Topographic", text: $settings.topographicTileURL)
                URLSettingField(title: "Dark", text: $settings.darkTileURL)
                URLSettingField(title: "Public OSM", text: $settings.publicOSMTileURL)
            }

            Section("Vector Style URLs") {
                URLSettingField(title: "OSM", text: $settings.vectorStyleOSMURL)
                URLSettingField(title: "Topographic", text: $settings.vectorStyleTopographicURL)
                URLSettingField(title: "Dark", text: $settings.vectorStyleDarkURL)
            }

            Section("Layers") {
                ForEach(MapOverlay.allCases) { overlay in
                    Toggle(overlay.localizedName, isOn: overlayBinding(overlay))
                }
                Text("Disabled layers do not issue network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Native Apple Map Fallback") {
                Picker("Fallback style", selection: $settings.mapSource) {
                    Text("Standard").tag("standard")
                    Text("Satellite").tag("satellite")
                    Text("Hybrid").tag("hybrid")
                    Text("Topographic").tag("topography")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func overlayBinding(_ overlay: MapOverlay) -> Binding<Bool> {
        Binding(
            get: { settings.mapOverlays.contains(overlay) },
            set: { enabled in
                var overlays = settings.mapOverlays
                if enabled {
                    overlays.insert(overlay)
                } else {
                    overlays.remove(overlay)
                }
                settings.mapOverlays = overlays
            }
        )
    }
}

private struct URLSettingField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField("https://…/{z}/{x}/{y}", text: $text)
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
        }
    }
}

// MARK: - Data

private struct DataSettingsPane: View {
    @Bindable var settings: SettingsService
    let telemetryDatabase: TelemetryDatabaseService

    @State private var confirmTelemetryDeletion = false
    @State private var isClearingTelemetry = false
    @State private var telemetryClearResult: String?
    @State private var telemetryClearError: String?

    init(
        settings: SettingsService,
        telemetryDatabase: TelemetryDatabaseService = .shared
    ) {
        self.settings = settings
        self.telemetryDatabase = telemetryDatabase
    }

    var body: some View {
        Form {
            Section("Messages") {
                Toggle("Store message history", isOn: $settings.messageHistoryEnabled)
                Picker("Retention", selection: $settings.messageRetention) {
                    ForEach(RetentionPeriod.allCases) { period in
                        Text(period.localizedName).tag(period)
                    }
                }
                .disabled(!settings.messageHistoryEnabled)
                Toggle("Show encrypted messages", isOn: $settings.showEncryptedMessages)
            }

            Section("Telemetry") {
                Picker("Retention", selection: $settings.telemetryRetention) {
                    ForEach(RetentionPeriod.allCases) { period in
                        Text(period.localizedName).tag(period)
                    }
                }
                Stepper(
                    "Signal analysis: \(settings.signalAnalysisWindowHours) hours",
                    value: $settings.signalAnalysisWindowHours,
                    in: 1...168
                )
                Stepper(
                    "Antenna analysis: \(settings.antennaAnalysisWindowDays) days",
                    value: $settings.antennaAnalysisWindowDays,
                    in: 1...365
                )

                Divider()

                HStack {
                    Button(
                        "Delete all telemetry data",
                        role: .destructive,
                        action: confirmTelemetryClear
                    )
                    .disabled(isClearingTelemetry)
                    if isClearingTelemetry {
                        ProgressView()
                            .controlSize(.small)
                        Text("Deleting telemetry data…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let telemetryClearResult {
                    Label(telemetryClearResult, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let telemetryClearError {
                    Label(telemetryClearError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Position History") {
                Stepper(
                    "History window: \(settings.positionHistoryHours) hours",
                    value: $settings.positionHistoryHours,
                    in: 0...8_760
                )
                Toggle("Enable location logging", isOn: $settings.locationLoggingEnabled)
            }

            Section("Node Keys") {
                Picker("When a public key changes", selection: $settings.nodeKeyMismatchPolicy) {
                    ForEach(NodeKeyMismatchPolicy.allCases) { action in
                        Text(action.localizedName).tag(action)
                    }
                }
            }

            Section("Own Position") {
                HStack {
                    TextField("Latitude", value: $settings.myLatitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                    TextField("Longitude", value: $settings.myLongitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Used for distance calculations when the connected node has no position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert(
            "Delete all telemetry data?",
            isPresented: $confirmTelemetryDeletion
        ) {
            Button("Delete", role: .destructive, action: clearTelemetry)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                String(localized: """
                    This deletes telemetry, packet history, and internal traceroute-hop data. \
                    Nodes, messages, settings, dashboards, and saved traceroute history remain.
                    """)
            )
        }
    }

    private func confirmTelemetryClear() {
        telemetryClearResult = nil
        telemetryClearError = nil
        confirmTelemetryDeletion = true
    }

    private func clearTelemetry() {
        guard !isClearingTelemetry else { return }
        isClearingTelemetry = true
        telemetryClearResult = nil
        telemetryClearError = nil
        Task {
            defer { isClearingTelemetry = false }
            do {
                let deletedRows = try await telemetryDatabase.clearAllTelemetry()
                telemetryClearResult = String(
                    localized: "\(deletedRows) telemetry records deleted."
                )
            } catch {
                telemetryClearError = error.localizedDescription
            }
        }
    }
}

// MARK: - Kiosk

private struct KioskSettingsPane: View {
    @Bindable var settings: SettingsService
    @Bindable var kioskState: KioskState
    @State private var password = ""
    @State private var confirmation = ""
    @State private var statusMessage: String?
    @State private var isSavingPassword = false
    @State private var confirmPasswordRemoval = false

    var body: some View {
        Form {
            Section("Kiosk / Training Mode") {
                Toggle("Enable kiosk mode", isOn: kioskEnabledBinding)
                Text("Selected functions are hidden while locked. This prevents mistakes but is not an attack boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Label(
                        kioskState.isLocked ? "Locked" : "Unlocked",
                        systemImage: kioskState.isLocked ? "lock.fill" : "lock.open.fill"
                    )
                    Spacer()
                    if settings.kioskModeEnabled, kioskState.hasPassword {
                        Button(kioskState.isLocked ? "Unlock" : "Lock", action: toggleLock)
                    }
                }

                if kioskState.recoveryRequired {
                    Label(
                        "The Keychain credential is missing. Set a new password to recover kiosk mode.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Password") {
                SecureField("New password", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Repeat password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(kioskState.hasPassword ? "Change password" : "Set password", action: savePassword)
                        .disabled(password.isEmpty || confirmation.isEmpty || isSavingPassword)
                    if isSavingPassword {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    if kioskState.hasPassword {
                        Button("Remove password", role: .destructive) {
                            confirmPasswordRemoval = true
                        }
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hide While Locked") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                    ForEach(KioskFeatureMask.allCases) { feature in
                        Toggle(feature.localizedName, isOn: featureBinding(feature))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Remove kiosk password?",
            isPresented: $confirmPasswordRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Password", role: .destructive, action: removePassword)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kiosk mode will be left unlocked until a new password is set.")
        }
    }

    private var kioskEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.kioskModeEnabled },
            set: { enabled in
                if enabled {
                    guard kioskState.hasPassword else {
                        statusMessage = String(localized: "Set a password before enabling kiosk mode.")
                        return
                    }
                    settings.kioskModeEnabled = true
                    kioskState.lock()
                } else {
                    kioskState.disable()
                }
            }
        )
    }

    private func featureBinding(_ feature: KioskFeatureMask) -> Binding<Bool> {
        Binding(
            get: { settings.kioskLockedFeatures.contains(feature) },
            set: { enabled in
                var mask = settings.kioskLockedFeatures
                if enabled {
                    mask.insert(feature)
                } else {
                    mask.remove(feature)
                }
                settings.kioskLockedFeatures = mask
            }
        )
    }

    private func savePassword() {
        guard password == confirmation else {
            statusMessage = String(localized: "The passwords do not match.")
            return
        }

        isSavingPassword = true
        Task {
            defer { isSavingPassword = false }
            do {
                try await kioskState.setPassword(password)
                password = ""
                confirmation = ""
                statusMessage = String(localized: "Kiosk password saved securely in Keychain.")
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func toggleLock() {
        if kioskState.isLocked {
            guard !password.isEmpty else {
                statusMessage = String(localized: "Enter the password in the password field to unlock.")
                return
            }
            Task {
                if await kioskState.unlock(with: password) {
                    password = ""
                    confirmation = ""
                    statusMessage = String(localized: "Kiosk mode unlocked.")
                } else {
                    statusMessage = kioskState.errorMessage
                }
            }
        } else {
            kioskState.lock()
            statusMessage = String(localized: "Kiosk mode locked.")
        }
    }

    private func removePassword() {
        do {
            try kioskState.removePassword()
            statusMessage = String(localized: "Kiosk password removed.")
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsPane: View {
    @Bindable var settings: SettingsService

    var body: some View {
        Form {
            Section("Alert Bell") {
                Toggle("Play sound on alert bell (🔔)", isOn: $settings.alertBellSound)
                Text("Messages containing 🔔 or the BEL character trigger the visual alert and optional sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Debug

private struct DebugSettingsPane: View {
    @Bindable var settings: SettingsService

    var body: some View {
        Form {
            Section("Debug Logging") {
                Toggle("Debug Messages", isOn: $settings.debugMessages)
                Toggle("Debug Serial", isOn: $settings.debugSerial)
                Toggle("Debug Device", isOn: $settings.debugDevice)
                Toggle("Debug Bluetooth", isOn: $settings.debugBluetooth)
            }
            .help("Enables verbose logging in the Debug tab")
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    SettingsView()
}
