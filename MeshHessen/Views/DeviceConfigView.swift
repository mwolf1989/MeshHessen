import SwiftUI

import SwiftProtobuf

/// Full local configuration editor. Remote nodes use the same editor and
/// transaction implementation through `RemoteAdminView`.
struct DeviceConfigView: View {
    var body: some View {
        NodeAdministrationView(target: .local, title: String(localized: "Device Configuration"))
    }
}

/// Entry point for a selected node. It intentionally owns no I/O; all reads,
/// writes, session handling, verification and reconnect behavior live in the
/// protocol service and coordinator.
struct RemoteAdminView: View {
    let nodeID: UInt32
    let nodeName: String

    var body: some View {
        NodeAdministrationView(
            target: .remote(nodeID),
            title: String(localized: "Remote Administration — \(nodeName)")
        )
    }
}

private struct NodeAdministrationView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appState) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: AdminTarget
    let title: String

    @State private var kioskState = KioskState.shared
    @State private var selection = AdministrationSection.overview
    @State private var original: MeshConfigurationSnapshot?
    @State private var draft = MeshConfigurationSnapshot()
    @State private var editorText = ""
    @State private var editorError: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var pendingDiff: MeshConfigurationDiff?
    @State private var showSaveConfirmation = false
    @State private var pendingAction: AdminNodeAction?
    @State private var pendingActionName = ""
    @State private var showActionConfirmation = false
    @State private var loadMode = AdministrationLoadMode.complete
    @State private var loadedSections: Set<AdministrationSection> = []
    @State private var showRemoteLoadChoice = false
    @State private var remoteFavoriteNodeID: UInt32?

    private var requiredFeature: KioskFeatureMask {
        target.isRemote ? .remoteAdmin : .nodeConfiguration
    }

    var body: some View {
        Group {
            if kioskState.isFeatureLocked(requiredFeature) {
                ContentUnavailableView(
                    "Feature Locked",
                    systemImage: "lock.shield",
                    description: Text("This administration feature is disabled in kiosk mode.")
                )
            } else {
                content
            }
        }
        .frame(minWidth: 920, minHeight: 650)
        .task {
            guard !kioskState.isFeatureLocked(requiredFeature), appState.protocolReady else { return }
            if target.isRemote {
                showRemoteLoadChoice = true
            } else {
                await loadAll()
            }
        }
        .confirmationDialog(
            "Load remote configuration",
            isPresented: $showRemoteLoadChoice,
            titleVisibility: .visible
        ) {
            Button("Load all sections now") {
                loadMode = .complete
                Task { await loadAll() }
            }
            Button("Load each section when opened") {
                loadMode = .lazy
                Task { await loadSection(.overview, force: true) }
            }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text("Loading section by section reduces mesh traffic. You can reload only the current section at any time.")
        }
        .alert(
            "Administration Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Write configuration?",
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Write, reconnect and verify") {
                Task { await saveConfirmed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDiff?.labels.joined(separator: ", ") ?? "")
        }
        .confirmationDialog(
            pendingActionName,
            isPresented: $showActionConfirmation,
            titleVisibility: .visible
        ) {
            Button(pendingActionName, role: .destructive) {
                if let action = pendingAction { Task { await run(action, named: pendingActionName) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This command changes or erases state on the selected node and cannot be undone.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            } detail: {
                detail
                    .padding()
            }
        }
        .onChange(of: selection) { _, newValue in
            prepareEditor()
            if loadMode == .lazy, !loadedSections.contains(newValue) {
                Task { await loadSection(newValue) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                if target.isRemote {
                    Text(remoteSecuritySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isLoading || isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(loadMode == .lazy ? "Reload Tab" : "Reload") {
                Task {
                    if loadMode == .lazy {
                        await loadSection(selection, force: true)
                    } else {
                        await loadAll()
                    }
                }
            }
                .disabled(isLoading || isSaving || !appState.protocolReady)
            Button("Review Changes") { reviewChanges() }
                .buttonStyle(.borderedProminent)
                .disabled(original == nil || isLoading || isSaving || !appState.protocolReady)
            Button("Close") { dismiss() }
                .disabled(isSaving)
        }
        .padding()
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "info.circle")
                .tag(AdministrationSection.overview)
            Section("Node") {
                Label("Owner", systemImage: "person.text.rectangle")
                    .tag(AdministrationSection.owner)
                Label("Fixed Position", systemImage: "mappin.and.ellipse")
                    .tag(AdministrationSection.fixedPosition)
                Label("Channels", systemImage: "dot.radiowaves.left.and.right")
                    .tag(AdministrationSection.channels)
            }
            Section("Configuration") {
                ForEach(MeshConfigCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(AdministrationSection.config(category))
                }
            }
            Section("Modules") {
                ForEach(MeshModuleConfigCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(AdministrationSection.module(category))
                }
            }
            Section("Administration") {
                Label("Actions", systemImage: "wrench.and.screwdriver")
                    .tag(AdministrationSection.actions)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview:
            overview
        case .owner:
            ownerEditor
        case .fixedPosition:
            fixedPositionEditor
        case .channels:
            channelEditor
        case .config(let category):
            configEditor(category)
        case .module(let category):
            moduleEditor(category)
        case .actions:
            actions
        }
    }

    private var overview: some View {
        Form {
            Section("Target") {
                LabeledContent("Node ID", value: targetNodeIDText)
                LabeledContent("Administration", value: target.isRemote ? "Remote mesh" : "Local transport")
                if let metadata = draft.metadata {
                    LabeledContent("Firmware", value: metadata.firmwareVersion)
                    LabeledContent("Hardware", value: String(describing: metadata.hwModel))
                    LabeledContent("Protobuf", value: metadata.deviceStateVersion.description)
                }
            }
            Section("Availability") {
                LabeledContent(
                    "Core configuration",
                    value: "\(draft.loadedConfigCategories.count) / \(MeshConfigCategory.allCases.count)"
                )
                LabeledContent(
                    "Module configuration",
                    value: "\(draft.loadedModuleCategories.count) / \(MeshModuleConfigCategory.allCases.count)"
                )
                if !missingCategories.isEmpty {
                    Text("Not supplied by this firmware: \(missingCategories.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if target.isRemote {
                Section("Remote security") {
                    Text(remoteSecuritySummary)
                    Text("The radio firmware selects the configured admin channel or PKI path. The session passkey is stored per node and renewed before expiry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var ownerEditor: some View {
        Form {
            Section("Node owner") {
                TextField("Long name", text: $draft.owner.longName)
                TextField("Short name", text: $draft.owner.shortName)
                Toggle("Licensed amateur radio", isOn: $draft.owner.isLicensed)
                Toggle("Cannot receive messages", isOn: $draft.owner.isUnmessagable)
            }
            Text("Meshtastic limits the long name to 39 characters and the short name to 4 characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(!draft.ownerLoaded)
    }

    private var fixedPositionEditor: some View {
        Form {
            Section("Fixed position") {
                Toggle(
                    "Use fixed position",
                    isOn: Binding(
                        get: { draft.fixedPosition != nil },
                        set: { enabled in
                            if enabled, draft.fixedPosition == nil { draft.fixedPosition = Meshtastic_Position() }
                            if !enabled { draft.fixedPosition = nil }
                        }
                    )
                )
                if draft.fixedPosition != nil {
                    decimalField("Latitude", value: fixedLatitude, width: 150)
                    decimalField("Longitude", value: fixedLongitude, width: 150)
                    integerField("Altitude (m)", value: fixedAltitude, width: 110)
                }
            }
            Text("Saving a fixed position also enables the corresponding position setting on the firmware.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var channelEditor: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(draft.channels.indices, id: \.self) { index in
                    ChannelConfigurationCard(channel: $draft.channels[index])
                }
                Button("Add secondary channel") {
                    let used = Set(draft.channels.map { Int($0.index) })
                    guard let free = (1..<8).first(where: { !used.contains($0) }) else { return }
                    var channel = Meshtastic_Channel()
                    channel.index = Int32(free)
                    channel.role = .secondary
                    draft.channels.append(channel)
                    draft.channels.sort { $0.index < $1.index }
                }
                .disabled(!draft.channelsLoaded || draft.channels.count >= 8)
            }
        }
    }

    @ViewBuilder
    private func configEditor(_ category: MeshConfigCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            editorHeading(
                title: category.title,
                available: draft.loadedConfigCategories.contains(category),
                fields: configSchemaFields[category] ?? []
            )
            if category == .security {
                Label(
                    "Private and admin keys are security-sensitive. Only write keys that belong to this node.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(.orange)
            }
            typedConfigEditor(category)
            AdvancedProtobufJSONEditor(
                text: $editorText,
                error: $editorError,
                refresh: prepareEditor
            ) {
                validateAndApplyEditor(for: .config(category))
            }
        }
        .disabled(!draft.loadedConfigCategories.contains(category))
    }

    @ViewBuilder
    private func moduleEditor(_ category: MeshModuleConfigCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            editorHeading(
                title: category.title,
                available: draft.loadedModuleCategories.contains(category),
                fields: moduleSchemaFields[category] ?? []
            )
            typedModuleEditor(category)
            AdvancedProtobufJSONEditor(
                text: $editorText,
                error: $editorError,
                refresh: prepareEditor
            ) {
                validateAndApplyEditor(for: .module(category))
            }
        }
        .disabled(!draft.loadedModuleCategories.contains(category))
    }

    @ViewBuilder
    private func typedConfigEditor(_ category: MeshConfigCategory) -> some View {
        switch category {
        case .device:
            DeviceConfigurationForm(config: $draft.device)
        case .position:
            PositionConfigurationForm(config: $draft.position)
        case .power:
            PowerConfigurationForm(config: $draft.power)
        case .network:
            NetworkConfigurationForm(config: $draft.network)
        case .display:
            DisplayConfigurationForm(config: $draft.display)
        case .lora:
            LoRaConfigurationForm(config: $draft.lora)
        case .bluetooth:
            BluetoothConfigurationForm(config: $draft.bluetooth)
        case .security:
            SecurityConfigurationForm(config: $draft.security)
        case .session, .deviceUI:
            ContentUnavailableView(
                "Advanced configuration",
                systemImage: "curlybraces",
                description: Text("This firmware-specific block is available in the advanced protobuf JSON editor below.")
            )
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func typedModuleEditor(_ category: MeshModuleConfigCategory) -> some View {
        switch category {
        case .mqtt:
            MQTTConfigurationForm(config: $draft.mqtt)
        case .telemetry:
            TelemetryConfigurationForm(config: $draft.telemetry)
        case .neighborInfo:
            NeighborInfoConfigurationForm(config: $draft.neighborInfo)
        case .storeForward:
            StoreForwardConfigurationForm(config: $draft.storeForward)
        case .externalNotification:
            ExternalNotificationConfigurationForm(
                config: $draft.externalNotification,
                ringtone: $draft.ringtone,
                ringtoneLoaded: draft.ringtoneLoaded
            )
        case .cannedMessage:
            CannedMessageConfigurationForm(
                config: $draft.cannedMessage,
                messageText: $draft.cannedMessageText,
                messageTextLoaded: draft.cannedMessageTextLoaded
            )
        case .rangeTest:
            RangeTestConfigurationForm(config: $draft.rangeTest)
        case .serial:
            SerialConfigurationForm(config: $draft.serial)
        default:
            ContentUnavailableView(
                "Advanced configuration",
                systemImage: "curlybraces",
                description: Text("This module remains fully editable in the advanced protobuf JSON editor below.")
            )
            .frame(maxHeight: .infinity)
        }
    }

    private func editorHeading(title: String, available: Bool, fields: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Label(available ? "Loaded" : "Not supported", systemImage: available ? "checkmark.circle" : "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(available ? .green : .secondary)
            }
            Text("Native controls validate common settings. The advanced protobuf JSON editor preserves access to every schema and unknown field.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("Available fields") {
                Text(fields.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private var actions: some View {
        Form {
            Section("Time and metadata") {
                Button("Synchronize node time") {
                    Task { await run(.synchronizeTime(Date()), named: String(localized: "Synchronize time")) }
                }
                Button("Refresh metadata") { Task { await loadSection(.overview, force: true) } }
                Button("Renew remote session") {
                    if case .remote(let nodeID) = target {
                        coordinator.protocol_.clearRemoteAdminSession(for: nodeID)
                        Task { await loadSection(selection, force: true) }
                    }
                }
                .disabled(!target.isRemote)
            }

            if !kioskState.isFeatureLocked(.quickConfiguration) {
                Section("Mesh Hessen") {
                    Button("Apply Mesh Hessen quick configuration") {
                        Task { await quickConfigure() }
                    }
                    Text("Sets SHORT_SLOW, hop limit 7, EU_868 when the region is unset, and adds the Mesh Hessen channel to the first free slot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if target.isRemote {
                Section("Favorites on Remote Node") {
                    Picker("Known node", selection: $remoteFavoriteNodeID) {
                        Text("Select a node").tag(Optional<UInt32>.none)
                        ForEach(appState.nodes.values.sorted { $0.name < $1.name }) { node in
                            Text("\(node.name) · \(node.nodeId)")
                                .tag(Optional(node.id))
                        }
                    }
                    HStack {
                        Button("Add Favorite") {
                            Task { await setRemoteFavorite(true) }
                        }
                        Button("Remove Favorite") {
                            Task { await setRemoteFavorite(false) }
                        }
                    }
                    .disabled(remoteFavoriteNodeID == nil || isSaving)
                    Text("The command changes the favorites stored in the selected remote node's NodeDB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Power") {
                Button("Reboot in 2 seconds") {
                    Task { await run(.reboot(afterSeconds: 2), named: String(localized: "Reboot")) }
                }
                Button("Shutdown in 2 seconds") {
                    confirm(.shutdown(afterSeconds: 2), named: String(localized: "Shutdown"))
                }
                .foregroundStyle(.red)
            }

            Section("Reset") {
                Button("Reset node database (preserve favorites)") {
                    confirm(.resetNodeDatabase(preserveFavorites: true), named: String(localized: "Reset NodeDB"))
                }
                Button("Reset configuration") {
                    confirm(.resetConfiguration(afterSeconds: 2), named: String(localized: "Reset configuration"))
                }
                Button("Factory reset device and BLE bonds") {
                    confirm(.factoryResetDevice(afterSeconds: 2), named: String(localized: "Factory reset"))
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Load / Save

    private func loadAll() async {
        isLoading = true
        statusMessage = String(localized: "Loading all configuration categories…")
        errorMessage = nil
        defer { isLoading = false }
        do {
            let snapshot = try await coordinator.requestCompleteConfiguration(from: target)
            original = snapshot
            draft = snapshot
            loadedSections = Set(AdministrationSection.allLoadableSections)
            prepareEditor()
            statusMessage = String(localized: "Configuration loaded")
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            statusMessage = String(localized: "Load failed")
            errorMessage = error.localizedDescription
        }
    }

    private func loadSection(_ section: AdministrationSection, force: Bool = false) async {
        guard force || !loadedSections.contains(section) else { return }
        isLoading = true
        statusMessage = String(localized: "Loading \(section.title)…")
        errorMessage = nil
        defer { isLoading = false }
        do {
            let incoming = try await coordinator.requestCompleteConfiguration(
                from: target,
                selection: section.requestSelection
            )
            var baseline = original ?? MeshConfigurationSnapshot()
            baseline.mergeLoaded(from: incoming)
            original = baseline
            draft.mergeLoaded(from: incoming)
            loadedSections.insert(section)
            prepareEditor()
            statusMessage = section.isAvailable(in: incoming)
                ? String(localized: "\(section.title) loaded")
                : String(localized: "\(section.title) is not supplied by this firmware")
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            statusMessage = String(localized: "Load failed")
            errorMessage = error.localizedDescription
        }
    }

    private func reviewChanges() {
        guard let original else { return }
        draft.owner.longName = String(draft.owner.longName.prefix(39))
        draft.owner.shortName = String(draft.owner.shortName.prefix(4))
        let diff = MeshConfigurationDiff.between(draft, and: original)
        guard !diff.isEmpty else {
            statusMessage = String(localized: "No changes")
            return
        }
        pendingDiff = diff
        showSaveConfirmation = true
    }

    private func saveConfirmed() async {
        guard let original else { return }
        isSaving = true
        statusMessage = String(localized: "Writing, reconnecting and verifying…")
        defer { isSaving = false }
        do {
            let diff = try await coordinator.saveCompleteConfiguration(draft, replacing: original, to: target)
            self.original = draft
            pendingDiff = nil
            statusMessage = String(localized: "Saved and verified: \(diff.labels.joined(separator: ", "))")
        } catch is CancellationError {
            statusMessage = nil
        } catch {
            statusMessage = String(localized: "Save failed")
            errorMessage = error.localizedDescription
        }
    }

    private func quickConfigure() async {
        isSaving = true
        statusMessage = String(localized: "Applying Mesh Hessen configuration…")
        defer { isSaving = false }
        do {
            let diff = try await coordinator.applyMeshHessenQuickConfiguration(to: target)
            statusMessage = diff.isEmpty
                ? String(localized: "Mesh Hessen configuration is already active")
                : String(localized: "Mesh Hessen configuration written")
            if loadMode == .lazy {
                await loadSection(selection, force: true)
            } else {
                await loadAll()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(_ action: AdminNodeAction, named name: String) {
        pendingAction = action
        pendingActionName = name
        showActionConfirmation = true
    }

    private func run(_ action: AdminNodeAction, named name: String) async {
        statusMessage = String(localized: "Sending \(name)…")
        do {
            _ = try await coordinator.performAdminAction(action, on: target)
            statusMessage = String(localized: "\(name) sent")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setRemoteFavorite(_ isFavorite: Bool) async {
        guard let nodeID = remoteFavoriteNodeID else { return }
        isSaving = true
        statusMessage = isFavorite
            ? String(localized: "Adding remote favorite…")
            : String(localized: "Removing remote favorite…")
        defer { isSaving = false }
        do {
            let sent = try await coordinator.setFavorite(
                isFavorite,
                nodeId: nodeID,
                on: target
            )
            statusMessage = sent
                ? String(localized: "Remote favorite command sent")
                : String(localized: "Remote favorite command could not be sent")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Protobuf JSON

    private func prepareEditor() {
        editorError = nil
        do {
            switch selection {
            case .config(let category):
                editorText = try prettyJSON(draft.config(for: category))
            case .module(let category):
                editorText = try prettyJSON(draft.moduleConfig(for: category))
            default:
                editorText = ""
            }
        } catch {
            editorText = ""
            editorError = error.localizedDescription
        }
    }

    private func applyEditor(for section: AdministrationSection) throws {
        switch section {
        case .config(let category):
            var decoded = try Meshtastic_Config(jsonString: editorText)
            guard configCategory(of: decoded) == category else {
                throw ConfigurationEditorError.wrongCategory(category.title)
            }
            preserveUnknownFields(in: &decoded, category: category)
            draft.apply(decoded)
        case .module(let category):
            var decoded = try Meshtastic_ModuleConfig(jsonString: editorText)
            guard moduleCategory(of: decoded) == category else {
                throw ConfigurationEditorError.wrongCategory(category.title)
            }
            preserveUnknownFields(in: &decoded, category: category)
            draft.apply(decoded)
        default:
            break
        }
        editorError = nil
    }

    private func preserveUnknownFields(
        in config: inout Meshtastic_Config,
        category: MeshConfigCategory
    ) {
        switch category {
        case .device: config.device.unknownFields = draft.device.unknownFields
        case .position: config.position.unknownFields = draft.position.unknownFields
        case .power: config.power.unknownFields = draft.power.unknownFields
        case .network: config.network.unknownFields = draft.network.unknownFields
        case .display: config.display.unknownFields = draft.display.unknownFields
        case .lora: config.lora.unknownFields = draft.lora.unknownFields
        case .bluetooth: config.bluetooth.unknownFields = draft.bluetooth.unknownFields
        case .security: config.security.unknownFields = draft.security.unknownFields
        case .session: config.sessionkey.unknownFields = draft.session.unknownFields
        case .deviceUI: config.deviceUi.unknownFields = draft.deviceUI.unknownFields
        }
    }

    private func preserveUnknownFields(
        in config: inout Meshtastic_ModuleConfig,
        category: MeshModuleConfigCategory
    ) {
        switch category {
        case .mqtt: config.mqtt.unknownFields = draft.mqtt.unknownFields
        case .serial: config.serial.unknownFields = draft.serial.unknownFields
        case .externalNotification:
            config.externalNotification.unknownFields = draft.externalNotification.unknownFields
        case .storeForward: config.storeForward.unknownFields = draft.storeForward.unknownFields
        case .rangeTest: config.rangeTest.unknownFields = draft.rangeTest.unknownFields
        case .telemetry: config.telemetry.unknownFields = draft.telemetry.unknownFields
        case .cannedMessage: config.cannedMessage.unknownFields = draft.cannedMessage.unknownFields
        case .audio: config.audio.unknownFields = draft.audio.unknownFields
        case .remoteHardware: config.remoteHardware.unknownFields = draft.remoteHardware.unknownFields
        case .neighborInfo: config.neighborInfo.unknownFields = draft.neighborInfo.unknownFields
        case .ambientLighting: config.ambientLighting.unknownFields = draft.ambientLighting.unknownFields
        case .detectionSensor: config.detectionSensor.unknownFields = draft.detectionSensor.unknownFields
        case .paxcounter: config.paxcounter.unknownFields = draft.paxcounter.unknownFields
        case .statusMessage: config.statusmessage.unknownFields = draft.statusMessage.unknownFields
        case .trafficManagement:
            config.trafficManagement.unknownFields = draft.trafficManagement.unknownFields
        case .tak: config.tak.unknownFields = draft.tak.unknownFields
        }
    }

    private func validateAndApplyEditor(for section: AdministrationSection) {
        do {
            try applyEditor(for: section)
            prepareEditor()
            statusMessage = String(localized: "Validated and applied \(section.title)")
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func prettyJSON<M: SwiftProtobuf.Message>(_ message: M) throws -> String {
        var options = JSONEncodingOptions()
        options.preserveProtoFieldNames = true
        options.useDeterministicOrdering = true
        let compact = try message.jsonString(options: options)
        guard let data = compact.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return compact }
        return String(decoding: prettyData, as: UTF8.self)
    }

    private func configCategory(of config: Meshtastic_Config) -> MeshConfigCategory? {
        switch config.payloadVariant {
        case .device: return .device
        case .position: return .position
        case .power: return .power
        case .network: return .network
        case .display: return .display
        case .lora: return .lora
        case .bluetooth: return .bluetooth
        case .security: return .security
        case .sessionkey: return .session
        case .deviceUi: return .deviceUI
        case nil: return nil
        }
    }

    private func moduleCategory(of config: Meshtastic_ModuleConfig) -> MeshModuleConfigCategory? {
        switch config.payloadVariant {
        case .mqtt: return .mqtt
        case .serial: return .serial
        case .externalNotification: return .externalNotification
        case .storeForward: return .storeForward
        case .rangeTest: return .rangeTest
        case .telemetry: return .telemetry
        case .cannedMessage: return .cannedMessage
        case .audio: return .audio
        case .remoteHardware: return .remoteHardware
        case .neighborInfo: return .neighborInfo
        case .ambientLighting: return .ambientLighting
        case .detectionSensor: return .detectionSensor
        case .paxcounter: return .paxcounter
        case .statusmessage: return .statusMessage
        case .trafficManagement: return .trafficManagement
        case .tak: return .tak
        case nil: return nil
        }
    }

    // MARK: - Derived values

    private var targetNodeIDText: String {
        switch target {
        case .local: return String(format: "!%08x", coordinator.protocol_.currentNodeId)
        case .remote(let nodeID): return String(format: "!%08x", nodeID)
        }
    }

    private var remoteSecuritySummary: String {
        guard case .remote(let nodeID) = target else { return String(localized: "Local authenticated admin session") }
        if appState.node(forId: nodeID)?.hasPublicKey == true {
            return String(localized: "PKI key available; per-node admin session enabled")
        }
        return String(localized: "No PKI key known; a configured admin channel may be required")
    }

    private var missingCategories: [String] {
        MeshConfigCategory.allCases
            .filter { !draft.loadedConfigCategories.contains($0) }
            .map(\.title)
            + MeshModuleConfigCategory.allCases
                .filter { !draft.loadedModuleCategories.contains($0) }
                .map(\.title)
    }

    private var fixedLatitude: Binding<Double> {
        Binding(
            get: { Double(draft.fixedPosition?.latitudeI ?? 0) / 1e7 },
            set: { draft.fixedPosition?.latitudeI = Int32(($0 * 1e7).rounded()) }
        )
    }

    private var fixedLongitude: Binding<Double> {
        Binding(
            get: { Double(draft.fixedPosition?.longitudeI ?? 0) / 1e7 },
            set: { draft.fixedPosition?.longitudeI = Int32(($0 * 1e7).rounded()) }
        )
    }

    private var fixedAltitude: Binding<Int32> {
        Binding(
            get: { draft.fixedPosition?.altitude ?? 0 },
            set: { draft.fixedPosition?.altitude = $0 }
        )
    }

    private func decimalField(_ title: String, value: Binding<Double>, width: CGFloat) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...7)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }

    private func integerField(_ title: String, value: Binding<Int32>, width: CGFloat) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }

    private let configSchemaFields: [MeshConfigCategory: [String]] = [
        .device: ["role", "serial_enabled", "button_gpio", "buzzer_gpio", "rebroadcast_mode", "node_info_broadcast_secs", "double_tap_as_button_press", "is_managed", "disable_triple_click", "tzdef", "led_heartbeat_disabled", "buzzer_mode"],
        .position: ["position_broadcast_secs", "position_broadcast_smart_enabled", "fixed_position", "gps_enabled", "gps_update_interval", "gps_attempt_time", "position_flags", "rx_gpio", "tx_gpio", "broadcast_smart_minimum_distance", "broadcast_smart_minimum_interval_secs", "gps_en_gpio", "gps_mode"],
        .power: ["is_power_saving", "on_battery_shutdown_after_secs", "adc_multiplier_override", "wait_bluetooth_secs", "sds_secs", "ls_secs", "min_wake_secs", "device_battery_ina_address", "powermon_enables"],
        .network: ["wifi_enabled", "wifi_ssid", "wifi_psk", "ntp_server", "eth_enabled", "address_mode", "ipv4_config", "rsyslog_server", "enabled_protocols", "ipv6_enabled"],
        .display: ["screen_on_secs", "gps_format", "auto_screen_carousel_secs", "compass_north_top", "flip_screen", "units", "oled", "displaymode", "heading_bold", "wake_on_tap_or_motion", "compass_orientation", "use_12h_clock", "use_long_node_name", "enable_message_bubbles"],
        .lora: ["use_preset", "modem_preset", "bandwidth", "spread_factor", "coding_rate", "frequency_offset", "region", "hop_limit", "tx_enabled", "tx_power", "channel_num", "override_duty_cycle", "sx126x_rx_boosted_gain", "override_frequency", "pa_fan_disabled", "ignore_incoming", "ignore_mqtt", "config_ok_to_mqtt"],
        .bluetooth: ["enabled", "mode", "fixed_pin"],
        .security: ["public_key", "private_key", "admin_key", "is_managed", "serial_enabled", "debug_log_api_enabled", "admin_channel_enabled"],
        .session: [],
        .deviceUI: ["version", "screen_brightness", "screen_timeout", "screen_lock", "settings_lock", "pin_code", "theme", "alert_enabled", "banner_enabled", "ring_tone_id", "language", "node_filter", "node_highlight", "calibration_data", "map_data", "compass_mode", "screen_rgb_color", "is_clockface_analog", "gps_format"],
    ]

    private let moduleSchemaFields: [MeshModuleConfigCategory: [String]] = [
        .mqtt: ["enabled", "address", "username", "password", "encryption_enabled", "json_enabled", "tls_enabled", "root", "proxy_to_client_enabled", "map_reporting_enabled", "map_report_settings"],
        .serial: ["enabled", "echo", "rxd", "txd", "baud", "timeout", "mode", "override_console_serial_port"],
        .externalNotification: ["enabled", "output_ms", "output", "output_vibra", "output_buzzer", "active", "alert_message", "alert_message_vibra", "alert_message_buzzer", "alert_bell", "alert_bell_vibra", "alert_bell_buzzer", "use_pwm", "nag_timeout", "use_i2s_as_buzzer"],
        .storeForward: ["enabled", "heartbeat", "records", "history_return_max", "history_return_window", "is_server"],
        .rangeTest: ["enabled", "sender", "save", "clear_on_reboot"],
        .telemetry: ["device_update_interval", "environment_update_interval", "environment_measurement_enabled", "environment_screen_enabled", "environment_display_fahrenheit", "air_quality_enabled", "air_quality_interval", "power_measurement_enabled", "power_update_interval", "power_screen_enabled", "health_measurement_enabled", "health_update_interval", "health_screen_enabled", "device_telemetry_enabled", "air_quality_screen_enabled"],
        .cannedMessage: ["rotary1_enabled", "inputbroker_pin_a", "inputbroker_pin_b", "inputbroker_pin_press", "inputbroker_event_cw", "inputbroker_event_ccw", "inputbroker_event_press", "updown1_enabled", "enabled", "allow_input_source", "send_bell"],
        .audio: ["codec2_enabled", "ptt_pin", "bitrate", "i2s_ws", "i2s_sd", "i2s_din", "i2s_sck"],
        .remoteHardware: ["enabled", "allow_undefined_pin_access", "available_pins"],
        .neighborInfo: ["enabled", "update_interval", "transmit_over_lora"],
        .ambientLighting: ["led_state", "current", "red", "green", "blue"],
        .detectionSensor: ["enabled", "minimum_broadcast_secs", "state_broadcast_secs", "send_bell", "name", "monitor_pin", "detection_trigger_type", "use_pullup"],
        .paxcounter: ["enabled", "paxcounter_update_interval", "wifi_threshold", "ble_threshold"],
        .statusMessage: ["node_status"],
        .trafficManagement: ["enabled", "position_dedup_enabled", "position_precision_bits", "position_min_interval_secs", "nodeinfo_direct_response", "nodeinfo_direct_response_max_hops", "rate_limit_enabled", "rate_limit_window_secs", "rate_limit_max_packets", "drop_unknown_enabled", "unknown_packet_threshold", "exhaust_hop_telemetry", "exhaust_hop_position", "router_preserve_hops"],
        .tak: ["team", "role"],
    ]
}

// MARK: - Native core configuration forms

private struct DeviceConfigurationForm: View {
    @Binding var config: Meshtastic_Config.DeviceConfig

    var body: some View {
        Form {
            Section("Mesh behavior") {
                Picker("Node role", selection: $config.role) {
                    ForEach(Meshtastic_Config.DeviceConfig.Role.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Rebroadcast mode", selection: $config.rebroadcastMode) {
                    ForEach(Meshtastic_Config.DeviceConfig.RebroadcastMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                UInt32ConfigurationField(
                    "Node-info interval (s)",
                    value: $config.nodeInfoBroadcastSecs,
                    range: 0...86_400
                )
                Toggle("Managed node", isOn: $config.isManaged)
            }
            Section("Hardware") {
                UInt32ConfigurationField("Button GPIO", value: $config.buttonGpio, range: 0...255)
                UInt32ConfigurationField("Buzzer GPIO", value: $config.buzzerGpio, range: 0...255)
                Picker("Buzzer mode", selection: $config.buzzerMode) {
                    ForEach(Meshtastic_Config.DeviceConfig.BuzzerMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Toggle("Double tap acts as button", isOn: $config.doubleTapAsButtonPress)
                Toggle("Disable triple click", isOn: $config.disableTripleClick)
                Toggle("Disable heartbeat LED", isOn: $config.ledHeartbeatDisabled)
            }
            Section("Time zone") {
                TextField("POSIX TZ definition", text: $config.tzdef)
                    .textFieldStyle(.roundedBorder)
                Text("Example for Germany: CET-1CEST,M3.5.0,M10.5.0/3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PositionConfigurationForm: View {
    @Binding var config: Meshtastic_Config.PositionConfig

    var body: some View {
        Form {
            Section("Position reporting") {
                Toggle("Fixed position", isOn: $config.fixedPosition)
                UInt32ConfigurationField(
                    "Broadcast interval (s)",
                    value: $config.positionBroadcastSecs,
                    range: 0...604_800
                )
                Toggle("Smart broadcasting", isOn: $config.positionBroadcastSmartEnabled)
                UInt32ConfigurationField(
                    "Smart minimum distance (m)",
                    value: $config.broadcastSmartMinimumDistance,
                    range: 0...100_000
                )
                UInt32ConfigurationField(
                    "Smart minimum interval (s)",
                    value: $config.broadcastSmartMinimumIntervalSecs,
                    range: 0...604_800
                )
            }
            Section("GPS") {
                Picker("GPS mode", selection: $config.gpsMode) {
                    ForEach(Meshtastic_Config.PositionConfig.GpsMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                UInt32ConfigurationField(
                    "GPS update interval (s)",
                    value: $config.gpsUpdateInterval,
                    range: 0...UInt32.max
                )
                UInt32ConfigurationField("GPS RX GPIO", value: $config.rxGpio, range: 0...255)
                UInt32ConfigurationField("GPS TX GPIO", value: $config.txGpio, range: 0...255)
                UInt32ConfigurationField("GPS enable GPIO", value: $config.gpsEnGpio, range: 0...255)
            }
            Section("Position packet fields") {
                PositionFlagToggle("Altitude", flag: .altitude, flags: $config.positionFlags)
                PositionFlagToggle("Altitude is MSL", flag: .altitudeMsl, flags: $config.positionFlags)
                PositionFlagToggle("Geoidal separation", flag: .geoidalSeparation, flags: $config.positionFlags)
                PositionFlagToggle("Dilution of precision", flag: .dop, flags: $config.positionFlags)
                PositionFlagToggle("Separate HDOP / VDOP", flag: .hvdop, flags: $config.positionFlags)
                PositionFlagToggle("Satellites in view", flag: .satinview, flags: $config.positionFlags)
                PositionFlagToggle("Sequence number", flag: .seqNo, flags: $config.positionFlags)
                PositionFlagToggle("Timestamp", flag: .timestamp, flags: $config.positionFlags)
                PositionFlagToggle("Heading", flag: .heading, flags: $config.positionFlags)
                PositionFlagToggle("Speed", flag: .speed, flags: $config.positionFlags)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PositionFlagToggle: View {
    let title: String
    let flag: Meshtastic_Config.PositionConfig.PositionFlags
    @Binding var flags: UInt32

    init(
        _ title: String,
        flag: Meshtastic_Config.PositionConfig.PositionFlags,
        flags: Binding<UInt32>
    ) {
        self.title = title
        self.flag = flag
        _flags = flags
    }

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { flags & UInt32(flag.rawValue) != 0 },
                set: { enabled in
                    let mask = UInt32(flag.rawValue)
                    flags = enabled ? flags | mask : flags & ~mask
                }
            )
        )
    }
}

private struct PowerConfigurationForm: View {
    @Binding var config: Meshtastic_Config.PowerConfig

    var body: some View {
        Form {
            Section("Power saving") {
                Toggle("Power saving", isOn: $config.isPowerSaving)
                UInt32ConfigurationField(
                    "Shutdown after battery loss (s)",
                    value: $config.onBatteryShutdownAfterSecs,
                    range: 0...2_592_000
                )
                UInt32ConfigurationField(
                    "Wait for Bluetooth (s)",
                    value: $config.waitBluetoothSecs,
                    range: 0...86_400
                )
                UInt32ConfigurationField("Super deep sleep (s)", value: $config.sdsSecs, range: 0...UInt32.max)
                UInt32ConfigurationField("Light sleep (s)", value: $config.lsSecs, range: 0...UInt32.max)
                UInt32ConfigurationField("Minimum wake time (s)", value: $config.minWakeSecs, range: 0...86_400)
            }
            Section("Battery measurement") {
                FloatConfigurationField(
                    "ADC multiplier",
                    value: Binding(
                        get: { config.adcMultiplierOverride },
                        set: { config.adcMultiplierOverride = $0 == 0 ? 0 : max(2, $0) }
                    ),
                    range: 0...6,
                    suggestedRange: "0 uses the board default; overrides must be between 2 and 6."
                )
                UInt32ConfigurationField(
                    "INA battery address",
                    value: $config.deviceBatteryInaAddress,
                    range: 0...127
                )
                UInt64ConfigurationField("Power-monitor flags", value: $config.powermonEnables)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NetworkConfigurationForm: View {
    @Binding var config: Meshtastic_Config.NetworkConfig

    var body: some View {
        Form {
            Section("Wi-Fi") {
                Toggle("Enable Wi-Fi", isOn: $config.wifiEnabled)
                TextField("SSID", text: $config.wifiSsid)
                    .textFieldStyle(.roundedBorder)
                SecureField("Wi-Fi password", text: $config.wifiPsk)
                    .textFieldStyle(.roundedBorder)
                TextField("NTP server", text: $config.ntpServer)
                    .textFieldStyle(.roundedBorder)
            }
            Section("Ethernet and addressing") {
                Toggle("Enable Ethernet", isOn: $config.ethEnabled)
                Picker("Address mode", selection: $config.addressMode) {
                    ForEach(Meshtastic_Config.NetworkConfig.AddressMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                if config.addressMode == .static {
                    IPv4ConfigurationField("IP address", value: $config.ipv4Config.ip)
                    IPv4ConfigurationField("Gateway", value: $config.ipv4Config.gateway)
                    IPv4ConfigurationField("Subnet mask", value: $config.ipv4Config.subnet)
                    IPv4ConfigurationField("DNS server", value: $config.ipv4Config.dns)
                }
                Toggle("Enable IPv6", isOn: $config.ipv6Enabled)
            }
            Section("Services") {
                TextField("Remote syslog server", text: $config.rsyslogServer)
                    .textFieldStyle(.roundedBorder)
                Toggle(
                    "UDP broadcast",
                    isOn: Binding(
                        get: { config.enabledProtocols & UInt32(Meshtastic_Config.NetworkConfig.ProtocolFlags.udpBroadcast.rawValue) != 0 },
                        set: { enabled in
                            let mask = UInt32(Meshtastic_Config.NetworkConfig.ProtocolFlags.udpBroadcast.rawValue)
                            config.enabledProtocols = enabled
                                ? config.enabledProtocols | mask
                                : config.enabledProtocols & ~mask
                        }
                    )
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DisplayConfigurationForm: View {
    @Binding var config: Meshtastic_Config.DisplayConfig

    var body: some View {
        Form {
            Section("Screen") {
                UInt32ConfigurationField("Screen-on time (s)", value: $config.screenOnSecs, range: 0...UInt32.max)
                UInt32ConfigurationField(
                    "Carousel interval (s)",
                    value: $config.autoScreenCarouselSecs,
                    range: 0...86_400
                )
                Picker("Units", selection: $config.units) {
                    ForEach(Meshtastic_Config.DisplayConfig.DisplayUnits.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("OLED type", selection: $config.oled) {
                    ForEach(Meshtastic_Config.DisplayConfig.OledType.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Display mode", selection: $config.displaymode) {
                    ForEach(Meshtastic_Config.DisplayConfig.DisplayMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Compass orientation", selection: $config.compassOrientation) {
                    ForEach(Meshtastic_Config.DisplayConfig.CompassOrientation.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
            }
            Section("Presentation") {
                Toggle("Flip screen", isOn: $config.flipScreen)
                Toggle("Bold heading", isOn: $config.headingBold)
                Toggle("Wake on tap or motion", isOn: $config.wakeOnTapOrMotion)
                Toggle("12-hour clock", isOn: $config.use12HClock)
                Toggle("Use long node names", isOn: $config.useLongNodeName)
                Toggle("Message bubbles", isOn: $config.enableMessageBubbles)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoRaConfigurationForm: View {
    @Binding var config: Meshtastic_Config.LoRaConfig

    var body: some View {
        Form {
            Section("Radio plan") {
                Picker("Region", selection: $config.region) {
                    ForEach(Meshtastic_Config.LoRaConfig.RegionCode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Toggle("Use modem preset", isOn: $config.usePreset)
                if config.usePreset {
                    Picker("Modem preset", selection: $config.modemPreset) {
                        ForEach(Meshtastic_Config.LoRaConfig.ModemPreset.allCases, id: \.rawValue) { value in
                            Text(protobufValueLabel(value)).tag(value)
                        }
                    }
                } else {
                    UInt32ConfigurationField("Bandwidth", value: $config.bandwidth, range: 7...1_625)
                    UInt32ConfigurationField("Spread factor", value: $config.spreadFactor, range: 7...12)
                    UInt32ConfigurationField("Coding-rate denominator", value: $config.codingRate, range: 5...8)
                }
                UInt32ConfigurationField("Hop limit", value: $config.hopLimit, range: 0...7)
                UInt32ConfigurationField("Channel number", value: $config.channelNum, range: 0...UInt32.max)
            }
            Section("Transmit and receive") {
                Toggle("Transmit enabled", isOn: $config.txEnabled)
                Int32ConfigurationField("TX power (dBm)", value: $config.txPower, range: -128...127)
                Toggle("Override duty-cycle limit", isOn: $config.overrideDutyCycle)
                Toggle("SX126x boosted RX gain", isOn: $config.sx126XRxBoostedGain)
                Toggle("Disable PA fan", isOn: $config.paFanDisabled)
                Toggle("Ignore MQTT-routed packets", isOn: $config.ignoreMqtt)
                Toggle("Allow outgoing packets on MQTT", isOn: $config.configOkToMqtt)
            }
            Section("Advanced RF") {
                FloatConfigurationField("Frequency offset", value: $config.frequencyOffset, range: -100...100)
                FloatConfigurationField("Override frequency (MHz)", value: $config.overrideFrequency, range: 0...10_000)
                NodeIDListField("Ignore incoming node IDs", values: $config.ignoreIncoming)
                Text("Use decimal IDs or !hex IDs, separated by commas. Regulatory overrides are the operator's responsibility.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BluetoothConfigurationForm: View {
    @Binding var config: Meshtastic_Config.BluetoothConfig

    var body: some View {
        Form {
            Section("Bluetooth") {
                Toggle("Enabled", isOn: $config.enabled)
                Picker("Pairing mode", selection: $config.mode) {
                    ForEach(Meshtastic_Config.BluetoothConfig.PairingMode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                if config.mode == .fixedPin {
                    UInt32ConfigurationField("Fixed PIN", value: $config.fixedPin, range: 0...999_999)
                    Text("A fixed Bluetooth PIN can contain at most six digits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SecurityConfigurationForm: View {
    @Binding var config: Meshtastic_Config.SecurityConfig

    var body: some View {
        Form {
            Section("Node keys") {
                Base64DataField("Public key", data: $config.publicKey, secure: false)
                Base64DataField("Private key", data: $config.privateKey, secure: true)
                Base64DataListField("Authorized admin keys", values: $config.adminKey)
                Text("Keys must be valid Base64. Invalid input remains visible but is not applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Administration") {
                Toggle("Managed node", isOn: $config.isManaged)
                Toggle("Serial console enabled", isOn: $config.serialEnabled)
                Toggle("Debug log API enabled", isOn: $config.debugLogApiEnabled)
                Toggle("Legacy admin channel enabled", isOn: $config.adminChannelEnabled)
                if config.adminChannelEnabled {
                    Label("The legacy admin channel is not authenticated with the node's private key.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Native module configuration forms

private struct MQTTConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.MQTTConfig

    var body: some View {
        Form {
            Section("Broker") {
                Toggle("Enable MQTT", isOn: $config.enabled)
                TextField("Broker address", text: $config.address)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $config.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $config.password)
                    .textFieldStyle(.roundedBorder)
                TextField("Root topic", text: $config.root)
                    .textFieldStyle(.roundedBorder)
                Toggle("TLS", isOn: $config.tlsEnabled)
            }
            Section("Packet format and proxy") {
                Toggle("Encrypted payloads", isOn: $config.encryptionEnabled)
                Toggle("JSON payloads", isOn: $config.jsonEnabled)
                Toggle("Proxy through connected client", isOn: $config.proxyToClientEnabled)
            }
            Section("Map reporting") {
                Toggle("Report node to map", isOn: $config.mapReportingEnabled)
                if config.mapReportingEnabled {
                    Toggle("Report location", isOn: $config.mapReportSettings.shouldReportLocation)
                    UInt32ConfigurationField(
                        "Publish interval (s)",
                        value: $config.mapReportSettings.publishIntervalSecs,
                        range: 0...604_800
                    )
                    UInt32ConfigurationField(
                        "Position precision (bits)",
                        value: $config.mapReportSettings.positionPrecision,
                        range: 0...32
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TelemetryConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.TelemetryConfig

    var body: some View {
        Form {
            Section("Device telemetry") {
                Toggle("Send device telemetry", isOn: $config.deviceTelemetryEnabled)
                UInt32ConfigurationField(
                    "Device interval (s)",
                    value: $config.deviceUpdateInterval,
                    range: 0...604_800
                )
            }
            Section("Environment") {
                Toggle("Measure environment", isOn: $config.environmentMeasurementEnabled)
                Toggle("Show environment screen", isOn: $config.environmentScreenEnabled)
                Toggle("Display Fahrenheit", isOn: $config.environmentDisplayFahrenheit)
                UInt32ConfigurationField(
                    "Environment interval (s)",
                    value: $config.environmentUpdateInterval,
                    range: 0...604_800
                )
            }
            Section("Air quality") {
                Toggle("Measure air quality", isOn: $config.airQualityEnabled)
                Toggle("Show air-quality screen", isOn: $config.airQualityScreenEnabled)
                UInt32ConfigurationField(
                    "Air-quality interval (s)",
                    value: $config.airQualityInterval,
                    range: 0...604_800
                )
            }
            Section("Power") {
                Toggle("Measure power", isOn: $config.powerMeasurementEnabled)
                Toggle("Show power screen", isOn: $config.powerScreenEnabled)
                UInt32ConfigurationField(
                    "Power interval (s)",
                    value: $config.powerUpdateInterval,
                    range: 0...604_800
                )
            }
            Section("Health") {
                Toggle("Measure health", isOn: $config.healthMeasurementEnabled)
                Toggle("Show health screen", isOn: $config.healthScreenEnabled)
                UInt32ConfigurationField(
                    "Health interval (s)",
                    value: $config.healthUpdateInterval,
                    range: 0...604_800
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NeighborInfoConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.NeighborInfoConfig

    var body: some View {
        Form {
            Section("Neighbor information") {
                Toggle("Enabled", isOn: $config.enabled)
                UInt32ConfigurationField(
                    "Update interval (s)",
                    value: Binding(
                        get: { config.updateInterval },
                        set: { config.updateInterval = $0 == 0 ? 0 : max(14_400, $0) }
                    ),
                    range: 0...604_800
                )
                Toggle("Transmit over LoRa", isOn: $config.transmitOverLora)
                Text("A non-zero update interval is limited to at least four hours by the firmware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StoreForwardConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.StoreForwardConfig

    var body: some View {
        Form {
            Section("Store & Forward") {
                Toggle("Enabled", isOn: $config.enabled)
                Toggle("Act as server", isOn: $config.isServer)
                Toggle("Heartbeat", isOn: $config.heartbeat)
                UInt32ConfigurationField("Stored records", value: $config.records, range: 0...1_000_000)
                UInt32ConfigurationField(
                    "Maximum returned records",
                    value: $config.historyReturnMax,
                    range: 0...1_000_000
                )
                UInt32ConfigurationField(
                    "History window (min)",
                    value: $config.historyReturnWindow,
                    range: 0...UInt32.max
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExternalNotificationConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.ExternalNotificationConfig
    @Binding var ringtone: String
    let ringtoneLoaded: Bool

    var body: some View {
        Form {
            Section("Outputs") {
                Toggle("Enabled", isOn: $config.enabled)
                UInt32ConfigurationField("Output duration (ms)", value: $config.outputMs, range: 0...3_600_000)
                UInt32ConfigurationField("Primary GPIO", value: $config.output, range: 0...255)
                UInt32ConfigurationField("Vibration GPIO", value: $config.outputVibra, range: 0...255)
                UInt32ConfigurationField("Buzzer GPIO", value: $config.outputBuzzer, range: 0...255)
                Toggle("Active high", isOn: $config.active)
                Toggle("Use PWM", isOn: $config.usePwm)
                Toggle("Use I²S speaker as buzzer", isOn: $config.useI2SAsBuzzer)
                UInt32ConfigurationField("Repeat timeout (s)", value: $config.nagTimeout, range: 0...86_400)
            }
            Section("Text-message alerts") {
                Toggle("Primary output", isOn: $config.alertMessage)
                Toggle("Vibration output", isOn: $config.alertMessageVibra)
                Toggle("Buzzer output", isOn: $config.alertMessageBuzzer)
            }
            Section("Bell alerts") {
                Toggle("Primary output", isOn: $config.alertBell)
                Toggle("Vibration output", isOn: $config.alertBellVibra)
                Toggle("Buzzer output", isOn: $config.alertBellBuzzer)
            }
            if ringtoneLoaded {
                Section("RTTTL ringtone") {
                    TextEditor(text: $ringtone)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                        .accessibilityLabel("RTTTL ringtone")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CannedMessageConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.CannedMessageConfig
    @Binding var messageText: String
    let messageTextLoaded: Bool

    var body: some View {
        Form {
            Section("Input device") {
                Toggle("Enable rotary encoder", isOn: $config.rotary1Enabled)
                Toggle("Enable up/down/select input", isOn: $config.updown1Enabled)
                UInt32ConfigurationField("Encoder A GPIO", value: $config.inputbrokerPinA, range: 0...255)
                UInt32ConfigurationField("Encoder B GPIO", value: $config.inputbrokerPinB, range: 0...255)
                UInt32ConfigurationField("Press GPIO", value: $config.inputbrokerPinPress, range: 0...255)
                Picker("Clockwise event", selection: $config.inputbrokerEventCw) {
                    ForEach(Meshtastic_ModuleConfig.CannedMessageConfig.InputEventChar.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Counter-clockwise event", selection: $config.inputbrokerEventCcw) {
                    ForEach(Meshtastic_ModuleConfig.CannedMessageConfig.InputEventChar.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Press event", selection: $config.inputbrokerEventPress) {
                    ForEach(Meshtastic_ModuleConfig.CannedMessageConfig.InputEventChar.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                TextField("Allowed input source", text: $config.allowInputSource)
                    .textFieldStyle(.roundedBorder)
                Toggle("Send bell with message", isOn: $config.sendBell)
            }
            if messageTextLoaded {
                Section("Canned messages") {
                    TextEditor(text: $messageText)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                        .accessibilityLabel("Canned message text")
                    Text("Separate messages according to the firmware format, usually with a vertical bar (|).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RangeTestConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.RangeTestConfig

    var body: some View {
        Form {
            Section("Range test") {
                Toggle("Enabled", isOn: $config.enabled)
                UInt32ConfigurationField("Sender interval (s)", value: $config.sender, range: 0...86_400)
                Toggle("Save CSV on node", isOn: $config.save)
                Toggle("Clear CSV on reboot", isOn: $config.clearOnReboot_p)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SerialConfigurationForm: View {
    @Binding var config: Meshtastic_ModuleConfig.SerialConfig

    var body: some View {
        Form {
            Section("Serial module") {
                Toggle("Enabled", isOn: $config.enabled)
                Picker("Mode", selection: $config.mode) {
                    ForEach(Meshtastic_ModuleConfig.SerialConfig.Serial_Mode.allCases, id: \.rawValue) { value in
                        Text(protobufValueLabel(value)).tag(value)
                    }
                }
                Picker("Baud rate", selection: $config.baud) {
                    ForEach(Meshtastic_ModuleConfig.SerialConfig.Serial_Baud.allCases, id: \.rawValue) { value in
                        Text(serialBaudLabel(value)).tag(value)
                    }
                }
                UInt32ConfigurationField("RX GPIO", value: $config.rxd, range: 0...255)
                UInt32ConfigurationField("TX GPIO", value: $config.txd, range: 0...255)
                UInt32ConfigurationField("Timeout", value: $config.timeout, range: 0...UInt32.max)
                Toggle("Echo", isOn: $config.echo)
                Toggle("Override console serial port", isOn: $config.overrideConsoleSerialPort)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Validated form controls

private struct UInt32ConfigurationField: View {
    let title: String
    @Binding var value: UInt32
    let range: ClosedRange<UInt32>

    init(_ title: String, value: Binding<UInt32>, range: ClosedRange<UInt32>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: boundedValue, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityLabel(title)
        }
    }

    private var boundedValue: Binding<UInt32> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct UInt64ConfigurationField: View {
    let title: String
    @Binding var value: UInt64

    init(_ title: String, value: Binding<UInt64>) {
        self.title = title
        _value = value
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel(title)
        }
    }
}

private struct Int32ConfigurationField: View {
    let title: String
    @Binding var value: Int32
    let range: ClosedRange<Int32>

    init(_ title: String, value: Binding<Int32>, range: ClosedRange<Int32>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: boundedValue, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityLabel(title)
        }
    }

    private var boundedValue: Binding<Int32> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct FloatConfigurationField: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let suggestedRange: String?

    init(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        suggestedRange: String? = nil
    ) {
        self.title = title
        _value = value
        self.range = range
        self.suggestedRange = suggestedRange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                TextField(title, value: boundedValue, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .accessibilityLabel(title)
            }
            if let suggestedRange {
                Text(suggestedRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var boundedValue: Binding<Float> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct Base64DataField: View {
    let title: String
    @Binding var data: Data
    let secure: Bool

    @State private var text = ""
    @State private var isValid = true

    init(_ title: String, data: Binding<Data>, secure: Bool) {
        self.title = title
        _data = data
        self.secure = secure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                Group {
                    if secure {
                        SecureField(title, text: $text)
                    } else {
                        TextField(title, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel(title)
            }
            if !isValid {
                Label("Invalid Base64; the stored key is unchanged.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { synchronizeFromData() }
        .onChange(of: text) { _, newValue in
            guard let decoded = Data(base64Encoded: newValue) else {
                isValid = false
                return
            }
            isValid = true
            if decoded != data { data = decoded }
        }
        .onChange(of: data) { _, _ in synchronizeFromData() }
    }

    private func synchronizeFromData() {
        guard Data(base64Encoded: text) != data else { return }
        text = data.base64EncodedString()
        isValid = true
    }
}

private struct Base64DataListField: View {
    let title: String
    @Binding var values: [Data]

    @State private var text = ""
    @State private var isValid = true

    init(_ title: String, values: Binding<[Data]>) {
        self.title = title
        _values = values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                SecureField("Base64 keys separated by semicolons", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel(title)
            }
            if !isValid {
                Label("At least one admin key is not valid Base64.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { synchronizeFromValues() }
        .onChange(of: text) { _, newValue in apply(newValue) }
        .onChange(of: values) { _, _ in synchronizeFromValues() }
    }

    private func apply(_ candidate: String) {
        let pieces = candidate
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let decoded = pieces.compactMap { Data(base64Encoded: $0) }
        guard decoded.count == pieces.count else {
            isValid = false
            return
        }
        isValid = true
        if decoded != values { values = decoded }
    }

    private func synchronizeFromValues() {
        let decodedText = text
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { Data(base64Encoded: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard decodedText != values else { return }
        text = values.map { $0.base64EncodedString() }.joined(separator: "; ")
        isValid = true
    }
}

private struct IPv4ConfigurationField: View {
    let title: String
    @Binding var value: UInt32

    @State private var text = ""
    @State private var isValid = true

    init(_ title: String, value: Binding<UInt32>) {
        self.title = title
        _value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                TextField("0.0.0.0", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(width: 160)
                    .accessibilityLabel(title)
            }
            if !isValid {
                Text("Enter four numbers between 0 and 255.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { synchronizeFromValue() }
        .onChange(of: text) { _, newValue in
            guard let parsed = parseIPv4(newValue) else {
                isValid = false
                return
            }
            isValid = true
            if parsed != value { value = parsed }
        }
        .onChange(of: value) { _, _ in synchronizeFromValue() }
    }

    private func synchronizeFromValue() {
        guard parseIPv4(text) != value else { return }
        text = ipv4String(value)
        isValid = true
    }
}

private struct NodeIDListField: View {
    let title: String
    @Binding var values: [UInt32]

    @State private var text = ""
    @State private var isValid = true

    init(_ title: String, values: Binding<[UInt32]>) {
        self.title = title
        _values = values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title) {
                TextField("!1234abcd, 12345", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel(title)
            }
            if !isValid {
                Text("Use decimal IDs or !hex IDs separated by commas.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { synchronizeFromValues() }
        .onChange(of: text) { _, newValue in
            guard let parsed = parseNodeIDs(newValue) else {
                isValid = false
                return
            }
            isValid = true
            if parsed != values { values = parsed }
        }
        .onChange(of: values) { _, _ in synchronizeFromValues() }
    }

    private func synchronizeFromValues() {
        guard parseNodeIDs(text) != values else { return }
        text = values.map { String(format: "!%08x", $0) }.joined(separator: ", ")
        isValid = true
    }
}

private func parseIPv4(_ text: String) -> UInt32? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var result: UInt32 = 0
    for part in parts {
        guard let octet = UInt8(part) else { return nil }
        result = (result << 8) | UInt32(octet)
    }
    return result
}

private func ipv4String(_ value: UInt32) -> String {
    [24, 16, 8, 0]
        .map { String((value >> UInt32($0)) & 0xff) }
        .joined(separator: ".")
}

private func parseNodeIDs(_ text: String) -> [UInt32]? {
    let pieces = text
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    var result: [UInt32] = []
    for piece in pieces {
        let normalized = piece.hasPrefix("!")
            ? String(piece.dropFirst())
            : piece.lowercased().hasPrefix("0x") ? String(piece.dropFirst(2)) : nil
        if let normalized, let value = UInt32(normalized, radix: 16) {
            result.append(value)
        } else if normalized == nil, let value = UInt32(piece) {
            result.append(value)
        } else {
            return nil
        }
    }
    return result
}

private func protobufValueLabel<T>(_ value: T) -> String {
    let raw = String(describing: value)
        .replacingOccurrences(of: "_", with: " ")
    var output = ""
    for character in raw {
        if character.isUppercase, !output.isEmpty, output.last != " " {
            output.append(" ")
        }
        output.append(character)
    }
    return output.prefix(1).uppercased() + output.dropFirst()
}

private func serialBaudLabel(_ value: Meshtastic_ModuleConfig.SerialConfig.Serial_Baud) -> String {
    switch value {
    case .baudDefault: return String(localized: "Board default")
    case .baud110: return "110"
    case .baud300: return "300"
    case .baud600: return "600"
    case .baud1200: return "1,200"
    case .baud2400: return "2,400"
    case .baud4800: return "4,800"
    case .baud9600: return "9,600"
    case .baud19200: return "19,200"
    case .baud38400: return "38,400"
    case .baud57600: return "57,600"
    case .baud115200: return "115,200"
    case .baud230400: return "230,400"
    case .baud460800: return "460,800"
    case .baud576000: return "576,000"
    case .baud921600: return "921,600"
    case .UNRECOGNIZED(let rawValue): return String(localized: "Unknown (\(rawValue))")
    }
}

private enum AdministrationSection: Hashable {
    case overview
    case owner
    case fixedPosition
    case channels
    case config(MeshConfigCategory)
    case module(MeshModuleConfigCategory)
    case actions

    var isProtobufEditor: Bool {
        switch self {
        case .config, .module: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .owner: return String(localized: "Owner")
        case .fixedPosition: return String(localized: "Fixed Position")
        case .channels: return String(localized: "Channels")
        case .config(let category): return category.title
        case .module(let category): return category.title
        case .actions: return String(localized: "Actions")
        }
    }

    var requestSelection: MeshConfigurationRequestSelection {
        switch self {
        case .overview, .actions: return .overview
        case .owner: return .owner
        case .fixedPosition: return .config(.position)
        case .channels: return .channels
        case .config(let category): return .config(category)
        case .module(let category): return .module(category)
        }
    }

    func isAvailable(in snapshot: MeshConfigurationSnapshot) -> Bool {
        switch self {
        case .overview, .actions: return snapshot.metadataLoaded
        case .owner: return snapshot.ownerLoaded
        case .fixedPosition: return snapshot.loadedConfigCategories.contains(.position)
        case .channels: return snapshot.channelsLoaded
        case .config(let category): return snapshot.loadedConfigCategories.contains(category)
        case .module(let category): return snapshot.loadedModuleCategories.contains(category)
        }
    }

    static var allLoadableSections: [AdministrationSection] {
        [.overview, .owner, .fixedPosition, .channels, .actions]
            + MeshConfigCategory.allCases.map(AdministrationSection.config)
            + MeshModuleConfigCategory.allCases.map(AdministrationSection.module)
    }
}

private enum AdministrationLoadMode {
    case complete
    case lazy
}

private enum ConfigurationEditorError: LocalizedError {
    case wrongCategory(String)

    var errorDescription: String? {
        switch self {
        case .wrongCategory(let category):
            return String(localized: "The JSON does not contain the expected \(category) configuration block.")
        }
    }
}

private struct AdvancedProtobufJSONEditor: View {
    @Binding var text: String
    @Binding var error: String?
    let refresh: () -> Void
    let validate: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Editing JSON does not discard fields unknown to the native form.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh from Form", action: refresh)
                }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(minHeight: 220, maxHeight: 300)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(error == nil ? Color.secondary.opacity(0.25) : Color.red, lineWidth: 1)
                    }
                    .accessibilityLabel("Protobuf JSON configuration")
                HStack {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Validate and Apply", action: validate)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced protobuf JSON", systemImage: "curlybraces")
                .font(.headline)
        }
    }
}

private struct ChannelConfigurationCard: View {
    @Binding var channel: Meshtastic_Channel

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Slot")
                    Text("\(channel.index)").monospacedDigit()
                }
                GridRow {
                    Text("Role")
                    Picker("Role", selection: $channel.role) {
                        ForEach(Meshtastic_Channel.Role.allCases, id: \.rawValue) { role in
                            Text(String(describing: role)).tag(role)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Name")
                    TextField("Channel name", text: $channel.settings.name)
                }
                GridRow {
                    Text("PSK (Base64)")
                    TextField("AQ==", text: pskBase64)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("MQTT")
                    HStack {
                        Toggle("Uplink", isOn: $channel.settings.uplinkEnabled)
                        Toggle("Downlink", isOn: $channel.settings.downlinkEnabled)
                    }
                }
                GridRow {
                    Text("Position precision")
                    TextField(
                        "Bits",
                        value: $channel.settings.moduleSettings.positionPrecision,
                        format: .number
                    )
                    .frame(width: 90)
                }
            }
        } label: {
            Label("Channel \(channel.index)", systemImage: "dot.radiowaves.left.and.right")
        }
    }

    private var pskBase64: Binding<String> {
        Binding(
            get: { channel.settings.psk.base64EncodedString() },
            set: { value in
                if let data = Data(base64Encoded: value) { channel.settings.psk = data }
            }
        )
    }
}
