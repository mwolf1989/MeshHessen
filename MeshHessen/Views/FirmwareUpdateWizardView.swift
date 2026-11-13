import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Guided firmware update (Tools): device & catalog → method → firmware → pre-flight → transfer → done.
/// Nothing is written to a device before the pre-flight page shows no red row and the user confirmed.
struct FirmwareUpdateWizardView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var session: FirmwareUpdateSession?

    var body: some View {
        Group {
            if let session {
                FirmwareUpdateWizardContent(session: session)
            } else {
                ProgressView()
                    .frame(minWidth: 760, minHeight: 600)
            }
        }
        .task {
            guard session == nil else { return }
            let created = FirmwareUpdateSession(host: coordinator)
            created.requestVolumeAccess = { directory in VolumeAccessPanel.request(pointingAt: directory) }
            session = created
            await created.loadCatalog()
        }
    }
}

// MARK: - Volume access

/// Folder picker that grants the sandboxed app write access to the UF2 boot drive.
@MainActor
enum VolumeAccessPanel {
    static func request(pointingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = Uf2VolumeFlasher.accessPrompt
        panel.prompt = String(localized: "Allow")
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Content

private struct FirmwareUpdateWizardContent: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: FirmwareUpdateSession

    @State private var showFileImporter = false
    @State private var showStartConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var showPrefetch = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 680)
        .interactiveDismissDisabled(session.isRunning)
        .onDisappear { session.close() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                session.selectLocalFile(url)
            }
        }
        .sheet(isPresented: $showPrefetch) {
            FirmwarePrefetchSheet(
                catalog: session.catalog,
                preselect: session.hardwareFromCatalog ? session.hardware : nil
            )
        }
        .alert("Start the firmware update?", isPresented: $showStartConfirmation) {
            Button("Start Update", role: .destructive) { session.startConfirmed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(startConfirmationText)
        }
        .alert("Cancel the transfer?", isPresented: $showCancelConfirmation) {
            Button("Cancel Transfer", role: .destructive) { session.cancelTransfer() }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("The transfer is still running. An ESP32 keeps its old firmware as long as the loader has not activated the new image. A UF2 bootloader stays on its drive; the copy can be repeated.")
        }
    }

    // MARK: Layout

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Firmware Update")
                    .font(.title2.bold())
                Text("Step \(session.step.rawValue) of 6 · \(stepTitle)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(session.step.rawValue), total: 6)
                .frame(width: 180)
                .accessibilityLabel("Wizard progress")
        }
        .padding(20)
    }

    private var stepTitle: String {
        switch session.step {
        case .device: String(localized: "Device & Catalog")
        case .method: String(localized: "Transfer Method")
        case .firmware: String(localized: "Choose Firmware")
        case .preflight: String(localized: "Check & Start")
        case .transfer: String(localized: "Transfer")
        case .done: String(localized: "Finished")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch session.step {
        case .device: DeviceStep(session: session)
        case .method: MethodStep(session: session)
        case .firmware:
            FirmwareStep(
                session: session,
                chooseFile: { showFileImporter = true },
                openPrefetch: { showPrefetch = true }
            )
        case .preflight: PreflightStep(session: session)
        case .transfer: TransferStep(session: session)
        case .done: DoneStep(session: session)
        }
    }

    private var footer: some View {
        HStack {
            if session.step == .done {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else if session.isRunning {
                Button("Cancel Transfer…") { showCancelConfirmation = true }
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if session.step.rawValue > 1, session.step.rawValue < FirmwareUpdateSession.Step.transfer.rawValue {
                Button("Back") { session.goBack() }
                    .disabled(session.isPreparing)
            }
            if session.step.rawValue < FirmwareUpdateSession.Step.preflight.rawValue {
                Button("Next") { session.goNext() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canGoNext)
            } else if session.step == .preflight {
                Button("Start Update…") { showStartConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canStart)
            }
        }
        .padding(16)
    }

    private var allowedFileTypes: [UTType] {
        switch session.method {
        case .wifiOta, .bleOta: [UTType(filenameExtension: "bin") ?? .data]
        case .bleDfu: [.zip]
        case .uf2: [UTType(filenameExtension: "uf2") ?? .data]
        case nil: [.data]
        }
    }

    private var startConfirmationText: String {
        let common = String(localized: "The device restarts into its update mode. Keep it powered and connected, and do not close the assistant until the transfer has finished.")
        switch session.method {
        case .wifiOta:
            return common + "\n\n" + String(localized: "The OTA loader verifies the SHA-256 hash before it activates the image; a failed or interrupted transfer leaves the old firmware on the device.")
        case .uf2:
            return common + "\n\n" + String(localized: "The UF2 bootloader stays on its drive until it received a complete image; an interrupted copy can be repeated.")
        default:
            return common
        }
    }
}

// MARK: - Step 1

private struct DeviceStep: View {
    @Bindable var session: FirmwareUpdateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates the firmware of the connected node: ESP32 over Wi-Fi, nRF52 and RP2040 through their USB boot drive. Firmware comes from the official Meshtastic releases or from a local file.")
                .foregroundStyle(.secondary)

            GroupBox("Device") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Device", value: deviceName)
                    LabeledContent("Architecture", value: session.hardware?.architecture.nonEmpty ?? "–")
                    LabeledContent("Firmware", value: session.facts.firmwareVersion ?? "–")
                    LabeledContent("Build target", value: session.facts.pioEnv ?? "–")
                    LabeledContent("Connection", value: connectionText)
                }
                .padding(4)
            }

            if !session.facts.isConnected {
                notice(
                    "No device connected. Recovery mode: a device that already shows its UF2 boot drive can still be flashed with a local file.",
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            if session.facts.isConnected, session.catalog?.isEmpty == false, !session.hardwareFromCatalog {
                notice(
                    "This hardware model is not in the catalog. File name and chip checks use the build target the device reports.",
                    systemImage: "questionmark.circle.fill",
                    color: .orange
                )
            }
            if let hardware = session.hardware, !hardware.activelySupported, session.hardwareFromCatalog {
                notice(
                    "This device is no longer actively supported by Meshtastic; new releases may not contain a build for it.",
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }

            HStack {
                if session.isLoadingCatalog {
                    ProgressView().controlSize(.small)
                    Text("Loading firmware catalog…")
                } else {
                    Label(catalogStatus, systemImage: catalogSymbol)
                        .foregroundStyle(catalogColor)
                }
                Spacer()
                Button("Refresh Catalog") {
                    Task { await session.loadCatalog(forceRefresh: true) }
                }
                .disabled(session.isLoadingCatalog)
            }
        }
    }

    private var deviceName: String {
        let model = session.facts.hwModelName.isEmpty ? "" : session.facts.hwModelName
        if let hardware = session.hardware, session.hardwareFromCatalog {
            return model.isEmpty || hardware.displayName == model ? hardware.displayName : "\(hardware.displayName) (\(model))"
        }
        return model.isEmpty ? "–" : model
    }

    private var connectionText: String {
        guard let target = session.connectionTarget else { return "–" }
        let detail: String
        switch target.parameters {
        case .serial(let port, _): detail = "USB · \(port)"
        case .bluetooth(_, let name): detail = "Bluetooth · \(name)"
        case .tcp(let host, let port): detail = "TCP · \(host):\(port)"
        }
        return session.facts.isConnected ? detail : detail + " " + String(localized: "(disconnected)")
    }

    private var catalogStatus: String {
        guard let catalog = session.catalog else { return "" }
        if catalog.isEmpty { return String(localized: "No firmware catalog available — only local files can be used.") }
        if catalog.isFromCache {
            let date = catalog.cacheDate?.formatted(date: .abbreviated, time: .shortened) ?? "?"
            return String(localized: "Catalog from cache (\(date))")
        }
        return String(localized: "Catalog loaded online")
    }

    private var catalogSymbol: String {
        guard let catalog = session.catalog else { return "circle" }
        if catalog.isEmpty { return "xmark.octagon.fill" }
        return catalog.isFromCache ? "externaldrive.fill" : "checkmark.circle.fill"
    }

    private var catalogColor: Color {
        guard let catalog = session.catalog else { return .secondary }
        if catalog.isEmpty { return .red }
        return catalog.isFromCache ? .orange : .green
    }
}

// MARK: - Step 2

private struct MethodStep: View {
    @Bindable var session: FirmwareUpdateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose how the firmware reaches the device. Unavailable methods show the reason. The mesh connection is released during the update.")
                .foregroundStyle(.secondary)

            ForEach(session.methodOptions) { option in
                Button {
                    session.selectMethod(option.method)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: session.method == option.method ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(option.availability.isAvailable ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(option.method)).font(.headline)
                            Text(description(option.method))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = option.availability.reason {
                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.availability.isAvailable)
                .accessibilityAddTraits(session.method == option.method ? .isSelected : [])
            }

            if FirmwareWizardLogic.showsWebFlasherHint(facts: session.facts, hardware: session.hardware) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("ESP32 over USB is not supported here. Configure Wi-Fi on the device, or use the Meshtastic web flasher in Chrome or Edge.", systemImage: "info.circle")
                    if let url = URL(string: FirmwareCatalogService.webFlasherURL) {
                        Link("Open flasher.meshtastic.org", destination: url)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func title(_ method: FirmwareUpdateMethod) -> String {
        switch method {
        case .wifiOta: String(localized: "Wi-Fi OTA (ESP32)")
        case .bleOta: String(localized: "Bluetooth OTA (ESP32)")
        case .bleDfu: String(localized: "Bluetooth DFU (nRF52)")
        case .uf2: String(localized: "USB drive (UF2, nRF52/RP2040)")
        }
    }

    private func description(_ method: FirmwareUpdateMethod) -> String {
        switch method {
        case .wifiOta:
            String(localized: "The device restarts into its OTA loader and receives the firmware over TCP port 3232. The loader checks the SHA-256 hash. Requires Wi-Fi configured on the node and the Mac on the same network.")
        case .bleOta:
            String(localized: "The device restarts into its OTA loader and receives the firmware over Bluetooth LE.")
        case .bleDfu:
            String(localized: "Nordic DFU through the Adafruit bootloader over Bluetooth.")
        case .uf2:
            String(localized: "The device restarts as a USB drive (bootloader); the .uf2 file is copied onto it. The safest way — a USB cable is required.")
        }
    }
}

// MARK: - Step 3

private struct FirmwareStep: View {
    @Bindable var session: FirmwareUpdateSession
    let chooseFile: () -> Void
    let openPrefetch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: Binding(
                get: { session.source },
                set: { session.selectSource($0) }
            )) {
                Text("Stable").tag(FirmwareUpdateSession.FirmwareSource.stable)
                Text("Alpha / pre-release").tag(FirmwareUpdateSession.FirmwareSource.alpha)
                Text("Local file").tag(FirmwareUpdateSession.FirmwareSource.local)
            }
            .pickerStyle(.segmented)
            .disabled(session.catalog?.releases.isEmpty ?? true)

            if session.source == .local {
                localFileSection
            } else {
                releaseSection
            }

            HStack {
                Button("Download Firmware for Offline Use…", action: openPrefetch)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var releaseSection: some View {
        if session.source == .alpha {
            Label("Alpha builds are pre-releases — bugs and incompatibilities in the mesh are possible.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if session.releases.isEmpty {
            Text("No releases available.")
                .foregroundStyle(.secondary)
        } else {
            if session.catalog?.isFromCache == true {
                Text("Offline — releases come from the cache. Only entries marked “available offline” already contain the file for this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Release", selection: Binding(
                get: { session.selectedRelease },
                set: { session.selectRelease($0) }
            )) {
                ForEach(session.releases, id: \.id) { release in
                    Text(releaseLabel(release)).tag(Optional(release))
                }
            }
            if let release = session.selectedRelease {
                versionLine(selected: release.version)
                targetLine
                GroupBox("Release Notes") {
                    ScrollView {
                        Text(release.releaseNotes.isEmpty ? String(localized: "No release notes.") : release.releaseNotes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
                if let url = URL(string: release.pageURL), !release.pageURL.isEmpty {
                    Link("Open Release Page", destination: url)
                }
            }
        }
    }

    @ViewBuilder
    private var localFileSection: some View {
        HStack {
            Button("Choose File…", action: chooseFile)
                .disabled(session.method == nil)
            Text(session.localFileURL?.lastPathComponent ?? String(localized: "No file selected"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if let error = session.localFileError {
            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
        if let inspection = session.localInspection {
            versionLine(selected: inspection.detectedVersion)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(inspection.items.enumerated()), id: \.offset) { _, item in
                    PreflightRow(item: FirmwarePreflightItem(level: item.level, text: item.message))
                }
            }
        }
    }

    @ViewBuilder
    private func versionLine(selected: String?) -> some View {
        if let selected {
            let verdict = FirmwareWizardLogic.versionVerdict(current: session.facts.firmwareVersion, selected: selected)
            Text("Firmware \(session.facts.firmwareVersion ?? "?") → \(selected): \(verdict.text)")
                .foregroundStyle(verdict == .downgrade ? .orange : .primary)
        }
    }

    @ViewBuilder
    private var targetLine: some View {
        if let target = session.hardware?.effectiveTarget, !target.isEmpty {
            switch session.releaseTargetAvailable {
            case .some(true):
                Label("The release contains a build for “\(target)”.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .some(false):
                Label("The release lists no build for “\(target)”.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .none:
                Text("Build target: \(target)").foregroundStyle(.secondary)
            }
        }
    }

    private func releaseLabel(_ release: FirmwareRelease) -> String {
        session.isCachedOffline(release)
            ? release.title + " · " + String(localized: "available offline")
            : release.title
    }
}

// MARK: - Step 4

private struct PreflightStep: View {
    @Bindable var session: FirmwareUpdateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The firmware is downloaded or read and checked. Red entries prevent the start; yellow entries are warnings.")
                .foregroundStyle(.secondary)

            if session.isPreparing {
                HStack {
                    if let value = session.downloadProgress {
                        ProgressView(value: value) { Text("Downloading firmware…") }
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(session.preflightItems.enumerated()), id: \.offset) { _, item in
                    PreflightRow(item: item)
                }
            }

            Toggle("Back up the device configuration first (saved in the app's firmware folder; contains channel keys)", isOn: $session.backupFirst)
                .disabled(!session.facts.isConnected || session.isPreparing)

            Text("Firmware updates are at your own risk. The assistant checks what can be checked on the Mac; power loss, radio dropouts or an unsuitable bootloader can still make a manual recovery necessary.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PreflightRow: View {
    let item: FirmwarePreflightItem

    var body: some View {
        Label {
            Text(item.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch item.level {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "checkmark.circle"
        }
    }

    private var color: Color {
        switch item.level {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

// MARK: - Step 5

private struct TransferStep: View {
    @Bindable var session: FirmwareUpdateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Transfer in progress — do not switch off or disconnect the device!", systemImage: "bolt.horizontal.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(session.phase?.text ?? "")
            if let fraction = session.phase?.fraction {
                ProgressView(value: fraction) {
                    Text("\(Int((fraction * 100).rounded())) %").monospacedDigit()
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            if session.isWaitingForDrive {
                HStack {
                    Text("If the device already shows its boot drive, select it manually.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose Boot Drive…") {
                        Task { await session.chooseDriveManually() }
                    }
                }
            }

            LogView(lines: session.log)
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: - Step 6

private struct DoneStep: View {
    @Bindable var session: FirmwareUpdateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.outcome {
            case .success(let text):
                Label(text, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .failure(let text):
                Label(String(localized: "Update failed: \(text)"), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .cancelled:
                Label("Cancelled by the user.", systemImage: "stop.circle.fill").foregroundStyle(.orange)
            case nil:
                EmptyView()
            }

            if let backupURL = session.backupURL {
                HStack {
                    Text("Configuration backup: \(backupURL.lastPathComponent)")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                    }
                }
            }

            if session.linkReleased {
                HStack {
                    Button("Reconnect") {
                        Task { await session.reconnect() }
                    }
                    .disabled(!session.canReconnect)
                    if session.isReconnecting {
                        ProgressView().controlSize(.small)
                        Text("Reconnecting and waiting for the device…")
                    } else if let version = session.reconnectedVersion {
                        Label("Connected — firmware \(version)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if session.reconnectTimedOut {
                        Text("The device did not answer within 120 seconds. Check it and connect manually.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !session.log.isEmpty {
                DisclosureGroup("Log") {
                    LogView(lines: session.log)
                }
            }
        }
    }
}

// MARK: - Helpers

private func notice(_ text: LocalizedStringKey, systemImage: String, color: Color) -> some View {
    Label(text, systemImage: systemImage)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
