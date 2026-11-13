import AppKit
import SwiftUI

/// Funk-Echo window ("Who's pinging us?"): journal of requests other stations sent to
/// our node plus statistics. Plan 018 adds further tabs to `RequestEchoTab`.
struct RequestEchoView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var settings = SettingsService.shared
    @State private var kioskState = KioskState.shared

    @State private var tab: RequestEchoTab = .journal
    @State private var rangeDays = 7
    @State private var typeFilter: RequestEchoType?
    @State private var searchText = ""
    @State private var records: [RequestEchoRecord] = []
    @State private var stats = RequestEchoStats()
    @State private var reloadGeneration = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var nodeInfoTarget: NodeInfo?

    private static let reloadDebounce: Duration = .milliseconds(600)

    var body: some View {
        Group {
            if kioskState.isFeatureLocked(.funkEcho) {
                ContentUnavailableView(
                    "Funk-Echo is locked",
                    systemImage: "lock.fill",
                    description: Text("Unlock kiosk mode to view the Funk-Echo journal.")
                )
            } else {
                content
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(String(localized: "📡 Who's pinging us?"))
        .task(id: reloadKey) { await reload() }
        .onChange(of: appState.lastRequestEcho) { _, _ in
            appState.requestEchoUnread = 0
            scheduleReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .telemetryDatabaseDidClear)) { _ in
            scheduleReload()
        }
        .onAppear { appState.requestEchoUnread = 0 }
        .onDisappear { debounceTask?.cancel() }
        .sheet(item: $nodeInfoTarget) { node in
            NodeInfoSheet(node: node)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            switch tab {
            case .journal:
                RequestEchoJournalList(
                    records: filteredRecords,
                    labels: labels,
                    tone: settings.funkEchoToneValue,
                    actions: rowActions
                )
            case .statistics:
                RequestEchoStatisticsView(
                    stats: stats,
                    rangeLabel: rangeLabel,
                    fullName: { labels.fullName($0) }
                )
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $tab) {
                ForEach(RequestEchoTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            Picker("Range", selection: $rangeDays) {
                Text("Last 24 h").tag(1)
                Text("Last 7 days").tag(7)
                Text("Last 30 days").tag(30)
            }
            .labelsHidden()
            .fixedSize()

            Picker("Type", selection: $typeFilter) {
                Text("All types").tag(RequestEchoType?.none)
                ForEach(RequestEchoType.allCases) { type in
                    Text(verbatim: "\(type.emoji) \(type.displayName)").tag(RequestEchoType?.some(type))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(tab != .journal)

            TextField("Filter by node (name, short name or !hex)", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)
                .disabled(tab != .journal)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Data

    private var reloadKey: String { "\(rangeDays)-\(reloadGeneration)" }

    private var rangeLabel: String {
        switch rangeDays {
        case 1: return String(localized: "Last 24 h")
        case 30: return String(localized: "Last 30 days")
        default: return String(localized: "Last 7 days")
        }
    }

    private var labels: RequestEchoNodeLabels {
        RequestEchoNodeLabels(nodes: appState.nodes)
    }

    private var filteredRecords: [RequestEchoRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let labels = labels
        return records.filter { record in
            if let typeFilter, record.typeRaw != typeFilter.rawValue { return false }
            guard !query.isEmpty else { return true }
            return labels.shortLabel(record.nodeId).localizedCaseInsensitiveContains(query)
                || labels.fullName(record.nodeId).localizedCaseInsensitiveContains(query)
                || String(format: "!%08x", record.nodeId).localizedCaseInsensitiveContains(query)
        }
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.reloadDebounce)
            guard !Task.isCancelled else { return }
            reloadGeneration &+= 1
        }
    }

    private func reload() async {
        let days = rangeDays
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let result = await Task.detached(priority: .utility) {
            let database = TelemetryDatabaseService.shared
            return (database.requestEchoJournal(since: since), database.requestEchoStats(days: days))
        }.value
        guard !Task.isCancelled else { return }
        records = result.0
        stats = result.1
    }

    // MARK: - Row Actions

    private var rowActions: RequestEchoRowActions {
        RequestEchoRowActions(
            node: { appState.node(forId: $0) },
            showNodeInfo: { node in nodeInfoTarget = node },
            showOnMap: { nodeId in
                coordinator.router.navigateToNodeOnMap(nodeNum: nodeId)
                NSApp.activate(ignoringOtherApps: true)
            },
            sendDirectMessage: { nodeId in
                appState.ensureDMConversation(for: nodeId)
                appState.dmTargetNodeId = nodeId
                openWindow(id: "dm")
            }
        )
    }
}

// MARK: - Tabs

enum RequestEchoTab: String, CaseIterable, Identifiable {
    case journal
    case statistics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: return String(localized: "📜 Journal")
        case .statistics: return String(localized: "📊 Statistics")
        }
    }
}

// MARK: - Helpers

/// Name lookups shared by the journal and the statistics.
struct RequestEchoNodeLabels {
    let nodes: [UInt32: NodeInfo]

    func shortLabel(_ nodeId: UInt32) -> String {
        if let node = nodes[nodeId] {
            let short = node.shortName.trimmingCharacters(in: .whitespaces)
            if !short.isEmpty { return short }
            let name = node.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return String(format: "!%08x", nodeId)
    }

    func fullName(_ nodeId: UInt32) -> String {
        if let node = nodes[nodeId] {
            let name = node.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return String(format: "!%08x", nodeId)
    }
}

private struct RequestEchoRowActions {
    let node: (UInt32) -> NodeInfo?
    let showNodeInfo: (NodeInfo) -> Void
    let showOnMap: (UInt32) -> Void
    let sendDirectMessage: (UInt32) -> Void
}

// MARK: - Journal

private struct RequestEchoJournalList: View {
    let records: [RequestEchoRecord]
    let labels: RequestEchoNodeLabels
    let tone: RequestEchoTone
    let actions: RequestEchoRowActions

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView(
                "No requests",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text(
                    "No requests recorded yet — as soon as another station wants something from your node, it shows up here."
                )
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            ForEach(group.records) { record in
                                RequestEchoJournalRow(record: record, labels: labels, tone: tone)
                                    .contextMenu { contextMenu(for: record) }
                            }
                        } header: {
                            Text(Self.dayTitle(group.day))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.background)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for record: RequestEchoRecord) -> some View {
        let node = actions.node(record.nodeId)
        Button("Node info") {
            if let node { actions.showNodeInfo(node) }
        }
        .disabled(node == nil)
        Button("📍 Show on map") { actions.showOnMap(record.nodeId) }
            .disabled(node?.latitude == nil || node?.longitude == nil)
        Button("Send DM") { actions.sendDirectMessage(record.nodeId) }
    }

    private var dayGroups: [(day: Date, records: [RequestEchoRecord])] {
        let calendar = Calendar.current
        var groups: [(day: Date, records: [RequestEchoRecord])] = []
        for record in records {
            let day = calendar.startOfDay(for: record.lastSeen)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(date: .numeric, time: .omitted)
    }
}

private struct RequestEchoJournalRow: View {
    let record: RequestEchoRecord
    let labels: RequestEchoNodeLabels
    let tone: RequestEchoTone

    private var color: Color {
        record.type.flatMap { Color(hex: $0.colorHex) } ?? .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(record.type?.emoji ?? "❔")
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                (Text(labels.fullName(record.nodeId)).fontWeight(.semibold)
                    + Text(verbatim: "  ")
                    + Text(message).foregroundStyle(.secondary))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if record.count > 1 {
                Text(verbatim: "×\(record.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }

    private var message: String {
        guard let type = record.type else { return record.typeRaw }
        return RequestEchoText.message(
            type: type,
            from: labels.shortLabel(record.nodeId),
            detail: record.detail,
            tone: tone
        )
    }

    private var subline: String {
        var parts = [record.lastSeen.formatted(date: .omitted, time: .shortened)]
        if let type = record.type {
            if type == .telemetry, let detail = record.detail, !detail.isEmpty {
                parts.append("\(type.displayName) · \(RequestEchoTelemetryDetail.label(for: detail))")
            } else {
                parts.append(type.displayName)
            }
        }
        parts.append(RequestEchoText.source(hops: record.hops, viaMqtt: record.viaMqtt))
        let route = record.routeNodeIds
        if !route.isEmpty {
            let path = route.map { labels.shortLabel($0) }.joined(separator: " → ")
            parts.append(String(localized: "via \(path)"))
        }
        if let expectation = RequestEchoExpectation.text(for: record.expected) {
            parts.append(expectation)
        }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Statistics

private struct RequestEchoStatisticsView: View {
    let stats: RequestEchoStats
    let rangeLabel: String
    let fullName: (UInt32) -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Curiosity radar · \(rangeLabel)")
                    .font(.headline)

                HStack(spacing: 10) {
                    tile(value: stats.totalRequests, title: String(localized: "Requests"))
                    tile(value: stats.stations, title: String(localized: "Stations"))
                    tile(value: stats.traceCount, title: String(localized: "Traces"))
                }

                if stats.totalRequests == 0 {
                    Text(
                        "No requests recorded yet — as soon as another station wants something from your node, it shows up here."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text("What did the others want to know?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    typeBars
                    if let top = stats.topNodes.first {
                        Text("Most curious node: \(fullName(top.nodeId)) · \(top.count) requests")
                            .foregroundStyle(Color(hex: RequestEchoType.telemetry.colorHex) ?? .green)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func tile(value: Int, title: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: "\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sortedTypes: [(raw: String, count: Int)] {
        stats.perType.map { ($0.key, $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.raw < $1.raw) }
    }

    private var sortedDetails: [(code: String, count: Int)] {
        stats.telemetryDetails.map { ($0.key, $0.value) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.code < $1.code) }
    }

    @ViewBuilder
    private var typeBars: some View {
        let maxCount = max(1, stats.perType.values.max() ?? 1)
        let detailMax = max(1, stats.telemetryDetails.values.max() ?? 1)
        ForEach(sortedTypes, id: \.raw) { entry in
            let type = RequestEchoType(rawValue: entry.raw)
            let color = type.flatMap { Color(hex: $0.colorHex) } ?? .secondary
            StatBarRow(
                label: "\(type?.emoji ?? "❔") \(type?.displayName ?? entry.raw)",
                count: entry.count,
                maxCount: maxCount,
                color: color,
                indent: 0,
                barHeight: 10
            )
            if type == .telemetry {
                ForEach(sortedDetails, id: \.code) { detail in
                    StatBarRow(
                        label: "└ \(RequestEchoTelemetryDetail.label(for: detail.code))",
                        count: detail.count,
                        maxCount: detailMax,
                        color: color.opacity(0.8),
                        indent: 18,
                        barHeight: 6
                    )
                }
            }
        }
    }
}

private struct StatBarRow: View {
    let label: String
    let count: Int
    let maxCount: Int
    let color: Color
    let indent: CGFloat
    let barHeight: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(indent > 0 ? .caption : .callout)
                .frame(width: 170 - indent, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                Capsule()
                    .fill(color)
                    .frame(
                        width: max(barHeight, proxy.size.width * CGFloat(count) / CGFloat(maxCount)),
                        height: barHeight
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Text(verbatim: "\(count)")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.leading, indent)
    }
}
