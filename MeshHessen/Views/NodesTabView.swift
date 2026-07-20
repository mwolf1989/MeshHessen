import SwiftUI

/// "Nodes" tab — a responsive Windows-compatible tile view with a compact table alternative.
struct NodesTabView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    @State private var settings = SettingsService.shared
    @State private var kioskState = KioskState.shared
    @State private var selectedNodeId: UInt32?
    @State private var ageFilter = NodeAgeFilter.all
    @State private var favoritesOnly = false
    @State private var infrastructureOnly = false
    @State private var directOnly = false
    @State private var hideMqttNodes = false
    @State private var showNodeInfo: NodeInfo?
    @State private var tracerouteTarget: NodeInfo?
    @State private var telemetryTarget: NodeInfo?
    @State private var remoteAdminTarget: NodeInfo?

    private var sortedNodes: [NodeInfo] {
        let filtered = appState.filteredNodes.filter { node in
            ageFilter.includes(lastHeard: node.lastHeard)
                && (!favoritesOnly || node.isFavorite)
                && (!infrastructureOnly || node.isInfrastructure)
                && (!directOnly || node.isDirectRF)
                && (!hideMqttNodes || !node.viaMqtt)
        }
        // NodeSortOrder also gives own, favorite and pinned nodes stable priority.
        return settings.nodeSortOrder.sorted(filtered)
    }

    var body: some View {
        Group {
            if settings.fancyNodeListEnabled {
                tileView
            } else {
                tableView
            }
        }
        .searchable(text: Binding(
            get: { appState.nodeFilter },
            set: { appState.nodeFilter = $0 }
        ), prompt: "Filter nodes")
        .safeAreaInset(edge: .top, spacing: 0) {
            nodeFilterBar
        }
        .navigationTitle("Nodes (\(sortedNodes.count))")
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .sheet(item: $tracerouteTarget) { node in
            TracerouteSheet(targetNodeId: node.id, targetName: node.name)
        }
        .sheet(item: $telemetryTarget) { node in
            TelemetryView(nodeId: node.id, nodeName: node.name)
        }
        .sheet(item: $remoteAdminTarget) { node in
            RemoteAdminView(nodeID: node.id, nodeName: node.name)
        }
    }

    // MARK: - Tile view

    private var tileView: some View {
        GeometryReader { proxy in
            ScrollView {
                if sortedNodes.isEmpty {
                    ContentUnavailableView.search(text: appState.nodeFilter)
                        .frame(maxWidth: .infinity, minHeight: max(220, proxy.size.height - 40))
                } else if proxy.size.width < 640 {
                    LazyVStack(spacing: 10) {
                        ForEach(sortedNodes) { node in
                            nodeTile(node)
                        }
                    }
                    .padding(12)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 290, maximum: 430), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(sortedNodes) { node in
                            nodeTile(node)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func nodeTile(_ node: NodeInfo) -> some View {
        NodeTileView(
            node: node,
            isSelected: selectedNodeId == node.id,
            isColorful: settings.colorfulNodeListEnabled
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            selectedNodeId = node.id
        }
        .onTapGesture(count: 2) {
            selectedNodeId = node.id
            showNodeInfo = node
        }
        .contextMenu {
            nodeContextMenu(node)
        }
        .accessibilityAction(named: "Show Info") {
            showNodeInfo = node
        }
        .accessibilityAction(named: "Send Direct Message") {
            openDirectMessage(to: node)
        }
    }

    // MARK: - Table view

    private var tableView: some View {
        Table(sortedNodes, selection: $selectedNodeId) {
            TableColumn("Name") { node in
                HStack(spacing: 6) {
                    priorityIndicator(for: node)
                    if !node.colorHex.isEmpty, let color = Color(hex: node.colorHex) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(node.name).lineLimit(1)
                    if node.viaMqtt {
                        Image(systemName: "cloud.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .help("MQTT")
                    }
                }
            }
            .width(min: 140, ideal: 190)

            TableColumn("Node ID") { node in
                Text(node.nodeId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Hardware / Role") { node in
                VStack(alignment: .leading, spacing: 1) {
                    if !node.hardwareModel.isEmpty && node.hardwareModel != "Unknown" {
                        Text(node.hardwareModel)
                    }
                    if !node.role.isEmpty {
                        Text(node.role).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Battery") { node in
                if node.batteryLevel > 0 || node.voltage > 0 {
                    VStack(alignment: .leading, spacing: 1) {
                        if node.batteryLevel > 0 {
                            Label("\(node.batteryLevel)%", systemImage: batteryIcon(node.batteryLevel))
                        }
                        if node.voltage > 0 {
                            Text(String(format: "%.2f V", node.voltage))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("Direct RF") { node in
                if node.isDirectRF {
                    VStack(alignment: .leading, spacing: 1) {
                        if let snr = node.directSnr {
                            Text(String(format: "%.1f dB", snr))
                        }
                        if let rssi = node.directRssi {
                            Text("\(rssi) dBm").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("Distance") { node in
                if node.distanceMeters > 0 {
                    Text(formattedDistance(node.distanceMeters)).font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("Last Heard") { node in
                if node.lastHeard > 0 {
                    let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(80)

            TableColumn("Note") { node in
                TextField("", text: Binding(
                    get: { node.note },
                    set: { newValue in
                        node.note = newValue
                        SettingsService.shared.setNote(newValue, for: node.id)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .accessibilityLabel("Note")
            }
            .width(min: 80, ideal: 130)
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            if let id = ids.first, let node = appState.node(forId: id) {
                nodeContextMenu(node)
            }
        } primaryAction: { ids in
            if let id = ids.first {
                showNodeInfo = appState.node(forId: id)
            }
        }
    }

    // MARK: - Controls and actions

    private var hasAdvancedFilter: Bool {
        ageFilter != .all || favoritesOnly || infrastructureOnly || directOnly || hideMqttNodes
    }

    private var nodeFilterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Last Heard", selection: $ageFilter) {
                    ForEach(NodeAgeFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                Divider()
                Toggle("Favorites only", isOn: $favoritesOnly)
                Toggle("Infrastructure only", isOn: $infrastructureOnly)
                Toggle("Direct RF only", isOn: $directOnly)
                Toggle("Hide MQTT nodes", isOn: $hideMqttNodes)
            } label: {
                Label(
                    "Filter",
                    systemImage: hasAdvancedFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
            .help("Advanced node filter")

            Menu {
                Picker("Sort By", selection: $settings.nodeSortOrder) {
                    ForEach(NodeSortOrder.allCases) { sortOrder in
                        Text(sortOrder.displayName).tag(sortOrder)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down.circle")
            }
            .help("Sort nodes")

            Picker("Display", selection: $settings.fancyNodeListEnabled) {
                Label("Table", systemImage: "tablecells").tag(false)
                Label("Tiles", systemImage: "rectangle.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("Switch between table and tile view")

            if settings.fancyNodeListEnabled {
                Toggle(isOn: $settings.colorfulNodeListEnabled) {
                    Label("Signal colors", systemImage: "paintpalette")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .help("Color tiles by signal quality")
            }

            Spacer()

            if hasAdvancedFilter {
                Button("Clear Filters", systemImage: "xmark.circle") {
                    ageFilter = .all
                    favoritesOnly = false
                    infrastructureOnly = false
                    directOnly = false
                    hideMqttNodes = false
                }
                .labelStyle(.iconOnly)
                .help("Clear filters")
            }

            Text("\(sortedNodes.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(sortedNodes.count) nodes")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: NodeInfo) -> some View {
        Button("Show Info…") { showNodeInfo = node }
        Button("Send Direct Message") { openDirectMessage(to: node) }
        Button("Show on Map") {
            coordinator.router.navigateToNodeOnMap(nodeNum: node.id)
        }
        Divider()
        Button(node.isFavorite ? "Remove Favorite" : "Add Favorite") {
            Task { await coordinator.protocol_.setFavorite(!node.isFavorite, nodeId: node.id) }
        }
        Button(node.isPinned ? "Unpin" : "Pin") {
            node.isPinned.toggle()
            coordinator.coreDataStore.updateNodePinState(nodeId: node.id, isPinned: node.isPinned)
        }
        if node.id != appState.myNodeInfo?.nodeId {
            Button("Traceroute") { tracerouteTarget = node }
        }
        Button("Telemetry") { telemetryTarget = node }
        if node.isFavorite, !kioskState.isFeatureLocked(.remoteAdmin) {
            Button("Remote Administration…") { remoteAdminTarget = node }
        }
        Menu("Request Information") {
            ForEach(NodeInfoRequestType.allCases) { requestType in
                Button {
                    Task { await coordinator.protocol_.requestNodeInfo(requestType, from: node.id) }
                } label: {
                    Label(requestType.displayName, systemImage: requestType.systemImage)
                }
            }
        }
        Menu("Copy") {
            Button("Copy Node ID") { copyToPasteboard(node.nodeId) }
            Button("Copy Name") { copyToPasteboard(node.name) }
            if node.hasPublicKey {
                Button("Copy Public Key") {
                    copyToPasteboard(node.publicKey.base64EncodedString())
                }
            }
        }
        Divider()
        Menu("Sort By") {
            ForEach(NodeSortOrder.allCases) { sortOrder in
                Button {
                    settings.nodeSortOrder = sortOrder
                } label: {
                    if settings.nodeSortOrder == sortOrder {
                        Label(sortOrder.displayName, systemImage: "checkmark")
                    } else {
                        Text(sortOrder.displayName)
                    }
                }
            }
        }
        Menu("Set Color") {
            ForEach(nodeColorPresets, id: \.hex) { preset in
                Button {
                    node.colorHex = preset.hex
                    SettingsService.shared.setColorHex(preset.hex, for: node.id)
                } label: {
                    Label(preset.name, systemImage: "circle.fill")
                        .foregroundStyle(Color(hex: preset.hex) ?? .gray)
                }
            }
            Divider()
            Button("Clear Color") {
                node.colorHex = ""
                SettingsService.shared.setColorHex("", for: node.id)
            }
        }
    }

    @ViewBuilder
    private func priorityIndicator(for node: NodeInfo) -> some View {
        if node.isOwnNode {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(Color.accentColor)
                .help("Own node")
        } else if node.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .help("Favorite")
        } else if node.isPinned {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .help("Pinned")
        }
    }

    private func openDirectMessage(to node: NodeInfo) {
        appState.ensureDMConversation(for: node.id)
        appState.dmTargetNodeId = node.id
        openWindow(id: "dm")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func batteryIcon(_ level: UInt32) -> String {
        switch level {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : String(format: "%.0f m", meters)
    }
}

// MARK: - Node tile

private struct NodeTileView: View {
    let node: NodeInfo
    let isSelected: Bool
    let isColorful: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116), alignment: .leading)],
                alignment: .leading,
                spacing: 7
            ) {
                directSignal
                battery
                distanceAndAltitude
                path
                environment
            }

            Spacer(minLength: 0)
            metadata
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tileBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    priorityIcons
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(node.shortName.isEmpty ? node.nodeId : node.shortName)
                        .font(.system(.caption, design: .monospaced))
                    Text(node.nodeId)
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if node.hasPublicKey {
                    statusIcon("lock.shield.fill", color: .green, help: "PKI public key")
                }
                if node.isInfrastructure {
                    statusIcon("server.rack", color: .purple, help: "Infrastructure node")
                }
                if node.viaMqtt {
                    statusIcon("cloud.fill", color: .blue, help: "Received via MQTT")
                }
            }
        }
    }

    @ViewBuilder
    private var priorityIcons: some View {
        if node.isOwnNode {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(Color.accentColor)
                .help("Own node")
        }
        if node.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .help("Favorite")
        }
        if node.isPinned {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .help("Pinned")
        }
    }

    @ViewBuilder
    private var directSignal: some View {
        if node.isDirectRF, node.directSnr != nil || node.directRssi != nil {
            metric(systemImage: "antenna.radiowaves.left.and.right", title: "Direct RF") {
                HStack(spacing: 5) {
                    if let snr = node.directSnr {
                        Text(String(format: "%.1f dB", snr))
                    }
                    if let rssi = node.directRssi {
                        Text("\(rssi) dBm")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var battery: some View {
        if node.batteryLevel > 0 || node.voltage > 0 {
            metric(systemImage: batteryIcon, title: "Power") {
                HStack(spacing: 5) {
                    if node.batteryLevel > 0 {
                        Text("\(node.batteryLevel)%")
                    }
                    if node.voltage > 0 {
                        Text(String(format: "%.2f V", node.voltage))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var distanceAndAltitude: some View {
        if node.distanceMeters > 0 || node.altitude != nil {
            metric(systemImage: "location.fill", title: "Position") {
                HStack(spacing: 5) {
                    if node.distanceMeters > 0 {
                        Text(formattedDistance)
                    }
                    if let altitude = node.altitude {
                        Text("\(altitude) m")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var path: some View {
        if node.viaMqtt || node.hopsAway != nil || node.lastTracerouteHopCount > 0 {
            metric(systemImage: "arrow.triangle.branch", title: "Path") {
                HStack(spacing: 5) {
                    if node.viaMqtt {
                        Text("MQTT")
                    } else if let hopsAway = node.hopsAway {
                        Text(hopsAway == 0 ? String(localized: "Direct RF") : localizedHopCount(hopsAway))
                    }
                    if node.lastTracerouteHopCount > 0 {
                        Text("TR \(localizedHopCount(node.lastTracerouteHopCount))")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var environment: some View {
        if node.temperature != nil
            || node.relativeHumidity != nil
            || node.barometricPressure != nil
            || node.airQualityIndex != nil
            || node.pm25 != nil
            || node.pm10 != nil {
            metric(systemImage: "thermometer.medium", title: "Environment") {
                HStack(spacing: 5) {
                    if let temperature = node.temperature {
                        Text(String(format: "%.1f °C", temperature))
                    }
                    if let humidity = node.relativeHumidity {
                        Text(String(format: "%.0f%%", humidity))
                    }
                    if let pressure = node.barometricPressure {
                        Text(String(format: "%.0f hPa", pressure))
                    }
                    if let aqi = node.airQualityIndex {
                        Text("AQI \(aqi)")
                    }
                    if let pm25 = node.pm25 {
                        Text("PM2.5 \(pm25)")
                    }
                    if let pm10 = node.pm10 {
                        Text("PM10 \(pm10)")
                    }
                }
            }
            .gridCellColumns(2)
        }
    }

    private var metadata: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if !node.hardwareModel.isEmpty && node.hardwareModel != "Unknown" {
                    Label(node.hardwareModel, systemImage: "cpu")
                }
                if !node.role.isEmpty {
                    Label(node.role, systemImage: "person.badge.shield.checkmark")
                }
                if !node.note.isEmpty {
                    Label(node.note, systemImage: "note.text")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Spacer()

            if node.lastHeard > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                Label {
                    Text(date, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(date.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    private func metric<Content: View>(
        systemImage: String,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                content()
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private func statusIcon(_ systemImage: String, color: Color, help: LocalizedStringKey) -> some View {
        Image(systemName: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .help(help)
    }

    private var tileBackground: Color {
        guard isColorful else { return Color(nsColor: .controlBackgroundColor) }
        if node.isDirectRF, let snr = node.directSnr {
            if snr >= 5 { return .green.opacity(0.12) }
            if snr >= 0 { return .yellow.opacity(0.13) }
            return .red.opacity(0.10)
        }
        if node.viaMqtt { return .blue.opacity(0.09) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if !node.colorHex.isEmpty, let color = Color(hex: node.colorHex) { return color.opacity(0.8) }
        return .secondary.opacity(0.25)
    }

    private var batteryIcon: String {
        switch node.batteryLevel {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }

    private var formattedDistance: String {
        node.distanceMeters >= 1_000
            ? String(format: "%.1f km", node.distanceMeters / 1_000)
            : String(format: "%.0f m", node.distanceMeters)
    }

    private var accessibilitySummary: Text {
        var details = [node.name, node.nodeId]
        if node.isOwnNode { details.append(String(localized: "Own node")) }
        if node.isFavorite { details.append(String(localized: "Favorite")) }
        if node.isPinned { details.append(String(localized: "Pinned")) }
        if node.isDirectRF, let signal = node.directSignalText { details.append(signal) }
        if node.batteryLevel > 0 { details.append("\(node.batteryLevel) percent battery") }
        if node.distanceMeters > 0 { details.append(formattedDistance) }
        return Text(details.joined(separator: ", "))
    }
}
