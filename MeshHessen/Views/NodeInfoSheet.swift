import SwiftUI

/// Preset color choices for quick node tagging.
let nodeColorPresets: [(name: String, hex: String)] = [
    (String(localized: "Red"),    "#FF3B30"),
    (String(localized: "Blue"),   "#007AFF"),
    (String(localized: "Green"),  "#34C759"),
    (String(localized: "Yellow"), "#FFD60A"),
    (String(localized: "Orange"), "#FF9500"),
    (String(localized: "Purple"), "#AF52DE"),
    (String(localized: "Cyan"),   "#32D4DE"),
    (String(localized: "Gray"),   "#8E8E93"),
]

/// Sheet showing detailed info for a single node with color/note editing.
struct NodeInfoSheet: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let node: NodeInfo
    @State private var colorHex: String = ""
    @State private var note: String = ""
    @State private var ownerShortName: String = ""
    @State private var ownerLongName: String = ""
    @State private var isSavingOwner = false
    @State private var showTraceroute = false
    @State private var showTelemetry = false
    @State private var showRemoteAdmin = false
    @State private var kioskState = KioskState.shared

    private var isOwnNode: Bool {
        appState.myNodeInfo?.nodeId == node.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(node.nodeId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showTelemetry = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Telemetry")
                if !isOwnNode {
                    Menu {
                        ForEach(NodeInfoRequestType.allCases) { requestType in
                            Button {
                                Task { await coordinator.protocol_.requestNodeInfo(requestType, from: node.id) }
                            } label: {
                                Label(requestType.displayName, systemImage: requestType.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Request information")
                    Button {
                        showTraceroute = true
                    } label: {
                        Image(systemName: "arrow.triangle.swap")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Traceroute")
                    Button {
                        Task { await coordinator.protocol_.setFavorite(!node.isFavorite, nodeId: node.id) }
                    } label: {
                        Image(systemName: node.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(node.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(node.isFavorite ? "Remove favorite" : "Add favorite")
                    if node.isFavorite, !kioskState.isFeatureLocked(.remoteAdmin) {
                        Button {
                            showRemoteAdmin = true
                        } label: {
                            Image(systemName: "gearshape.2.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remote Administration")
                    }
                }
                Button {
                    node.isPinned.toggle()
                    coordinator.coreDataStore.updateNodePinState(nodeId: node.id, isPinned: node.isPinned)
                } label: {
                    Image(systemName: node.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(node.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(node.isPinned ? "Unpin node" : "Pin node")
                Button("Done") { saveAndDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Divider()

            // Details grid
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Short Name").foregroundStyle(.secondary)
                    Text(node.shortName).fontWeight(.medium)
                }
                GridRow {
                    Text("Long Name").foregroundStyle(.secondary)
                    Text(node.longName).fontWeight(.medium)
                }
                if !node.hardwareModel.isEmpty && node.hardwareModel != "Unknown" {
                    GridRow {
                        Text("Hardware").foregroundStyle(.secondary)
                        Text(node.hardwareModel)
                    }
                }
                if !node.firmwareVersion.isEmpty {
                    GridRow {
                        Text("Firmware").foregroundStyle(.secondary)
                        Text(node.firmwareVersion)
                    }
                }
                if !node.role.isEmpty {
                    GridRow {
                        Text("Role").foregroundStyle(.secondary)
                        Text(node.role)
                    }
                }
                if node.batteryLevel > 0 {
                    GridRow {
                        Text("Battery").foregroundStyle(.secondary)
                        Text("\(node.batteryLevel)%")
                    }
                }
                if node.snrFloat != 0 {
                    GridRow {
                        Text("SNR").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dB", node.snrFloat))
                    }
                }
                if let directRssi = node.directRssi {
                    GridRow {
                        Text("Direct RSSI").foregroundStyle(.secondary)
                        Text("\(directRssi) dBm")
                    }
                }
                if node.viaMqtt || node.hopsAway != nil {
                    GridRow {
                        Text("Path").foregroundStyle(.secondary)
                        if node.viaMqtt {
                            Label("MQTT", systemImage: "cloud")
                        } else if let hopsAway = node.hopsAway {
                            Text(hopsAway == 0 ? String(localized: "Direct RF") : localizedHopCount(hopsAway))
                        }
                    }
                }
                if node.voltage > 0 {
                    GridRow {
                        Text("Voltage").foregroundStyle(.secondary)
                        Text(node.voltage, format: .number.precision(.fractionLength(2))) + Text(" V")
                    }
                }
                if node.distanceMeters > 0 {
                    GridRow {
                        Text("Distance").foregroundStyle(.secondary)
                        let km = node.distanceMeters / 1000
                        Text(km >= 1 ? String(format: "%.2f km", km) : String(format: "%.0f m", node.distanceMeters))
                    }
                }
                if let lat = node.latitude, let lon = node.longitude {
                    GridRow {
                        Text("Position").foregroundStyle(.secondary)
                        Text(String(format: "%.5f, %.5f", lat, lon))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                if node.lastHeard > 0 {
                    GridRow {
                        Text("Last Heard").foregroundStyle(.secondary)
                        let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(date, style: .relative) + Text(" ago")
                            Text(date, format: .dateTime.day().month().year().hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if node.hasPublicKey {
                    GridRow {
                        Text("Public Key").foregroundStyle(.secondary)
                        HStack {
                            Text(node.publicKey.base64EncodedString())
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.publicKey.base64EncodedString(), forType: .string)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if hasExtendedTelemetry {
                Divider()
                extendedTelemetry
            }

            Divider()

            if isOwnNode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Node Settings")
                        .font(.headline)

                    HStack {
                        Text("Short Name")
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("ABCD", text: $ownerShortName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }

                    HStack {
                        Text("Long Name")
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("My Node", text: $ownerLongName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Spacer()
                        Button {
                            saveOwnerSettings()
                        } label: {
                            if isSavingOwner {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Save to Node")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingOwner || ownerShortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Divider()
            }

            // Color + note editing
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Color Tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("#RRGGBB", text: $colorHex)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .font(.system(.caption, design: .monospaced))
                        if !colorHex.isEmpty, let color = Color(hex: colorHex) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color)
                                .frame(width: 24, height: 24)
                        }
                        Button("Clear") { colorHex = "" }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    // Preset color swatches
                    HStack(spacing: 6) {
                        ForEach(nodeColorPresets, id: \.hex) { preset in
                            Button {
                                colorHex = preset.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: preset.hex) ?? .gray)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
                                    )
                                    .overlay(
                                        colorHex.uppercased() == preset.hex.uppercased()
                                            ? Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                            : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional note…", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200)
                }
            }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480, idealHeight: 620)
        .sheet(isPresented: $showTraceroute) {
            TracerouteSheet(targetNodeId: node.id, targetName: node.name)
        }
        .sheet(isPresented: $showTelemetry) {
            TelemetryView(nodeId: node.id, nodeName: node.name)
        }
        .sheet(isPresented: $showRemoteAdmin) {
            RemoteAdminView(nodeID: node.id, nodeName: node.name)
        }
        .onAppear {
            // Load persisted values from UserDefaults, falling back to in-memory model
            let savedColor = SettingsService.shared.colorHex(for: node.id)
            colorHex = savedColor.isEmpty ? node.colorHex : savedColor
            let savedNote = SettingsService.shared.note(for: node.id)
            note = savedNote.isEmpty ? node.note : savedNote

            ownerShortName = appState.myNodeInfo?.shortName.isEmpty == false
                ? (appState.myNodeInfo?.shortName ?? node.shortName)
                : node.shortName
            ownerLongName = appState.myNodeInfo?.longName.isEmpty == false
                ? (appState.myNodeInfo?.longName ?? node.longName)
                : node.longName
        }
    }

    private var hasExtendedTelemetry: Bool {
        node.temperature != nil
            || node.relativeHumidity != nil
            || node.barometricPressure != nil
            || node.pm25 != nil
            || node.pm10 != nil
            || node.paxMetrics != nil
            || node.localStats != nil
            || node.hostMetrics != nil
    }

    private var extendedTelemetry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest Telemetry")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let temperature = node.temperature {
                    GridRow {
                        Text("Temperature").foregroundStyle(.secondary)
                        Text(temperature, format: .number.precision(.fractionLength(1))) + Text(" °C")
                    }
                }
                if let humidity = node.relativeHumidity {
                    GridRow {
                        Text("Humidity").foregroundStyle(.secondary)
                        Text(humidity, format: .number.precision(.fractionLength(0))) + Text(" %")
                    }
                }
                if let pressure = node.barometricPressure {
                    GridRow {
                        Text("Pressure").foregroundStyle(.secondary)
                        Text(pressure, format: .number.precision(.fractionLength(0))) + Text(" hPa")
                    }
                }
                if let pm25 = node.pm25 {
                    GridRow {
                        Text("PM2.5").foregroundStyle(.secondary)
                        Text("\(pm25) µg/m³")
                    }
                }
                if let pm10 = node.pm10 {
                    GridRow {
                        Text("PM10").foregroundStyle(.secondary)
                        Text("\(pm10) µg/m³")
                    }
                }
                if let pax = node.paxMetrics {
                    GridRow {
                        Text("PAX Counter").foregroundStyle(.secondary)
                        Text("Wi-Fi \(pax.wifi) · BLE \(pax.ble)")
                    }
                }
                if let local = node.localStats {
                    GridRow {
                        Text("Mesh Packets").foregroundStyle(.secondary)
                        Text("TX \(local.packetsTx) · RX \(local.packetsRx) · Bad \(local.packetsRxBad)")
                    }
                }
                if let host = node.hostMetrics {
                    GridRow {
                        Text("Host Load").foregroundStyle(.secondary)
                        Text(String(format: "%.2f · %.2f · %.2f", Double(host.load1) / 100, Double(host.load5) / 100, Double(host.load15) / 100))
                    }
                }
            }
        }
    }

    private func saveAndDismiss() {
        node.colorHex = colorHex
        node.note = note
        // Persist via UserDefaults (legacy) + CoreData (primary)
        SettingsService.shared.setColorHex(colorHex, for: node.id)
        SettingsService.shared.setNote(note, for: node.id)
        coordinator.coreDataStore.updateNodeCustomization(nodeId: node.id, colorHex: colorHex, note: note)
        dismiss()
    }

    private func saveOwnerSettings() {
        let short = ownerShortName.trimmingCharacters(in: .whitespacesAndNewlines)
        let long = ownerLongName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return }

        isSavingOwner = true
        Task { @MainActor in
            await coordinator.updateOwner(shortName: short, longName: long)
            node.shortName = short
            node.longName = long
            node.name = long.isEmpty ? short : long
            appState.myNodeInfo?.shortName = short
            appState.myNodeInfo?.longName = long
            isSavingOwner = false
        }
    }
}
