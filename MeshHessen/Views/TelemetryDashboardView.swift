import SwiftUI
import UniformTypeIdentifiers

/// Customizable multi-dashboard telemetry surface matching the Windows client's
/// dashboard feature set.
struct TelemetryDashboardView: View {
    let nodeNames: [UInt32: String]
    let database: TelemetryDatabaseService

    @State private var store = TelemetryDashboardStore.shared
    @State private var editorRequest: TelemetryWidgetEditorRequest?
    @State private var refreshToken = 0
    @State private var autoRefreshSeconds = 0
    @State private var dashboardName = ""
    @State private var dashboardAction: DashboardNameAction?
    @State private var dashboardPendingDeletion: TelemetryDashboard?
    @State private var exportDocument = TelemetryCSVDocument(text: "")
    @State private var isExporting = false

    init(
        nodeNames: [UInt32: String],
        database: TelemetryDatabaseService = .shared
    ) {
        self.nodeNames = nodeNames
        self.database = database
    }

    var body: some View {
        VStack(spacing: 0) {
            dashboardToolbar
            Divider()
            dashboardContent
        }
        .sheet(item: $editorRequest) { request in
            TelemetryWidgetEditor(
                request: request,
                nodeNames: nodeNames,
                onSave: saveWidget
            )
        }
        .alert(
            dashboardAction?.title ?? String(localized: "Dashboard"),
            isPresented: dashboardNameAlertBinding
        ) {
            TextField("Name", text: $dashboardName)
            Button("Abbrechen", role: .cancel) { dashboardAction = nil }
            Button("Sichern", action: commitDashboardName)
                .disabled(dashboardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Dashboard löschen?",
            isPresented: dashboardDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive, action: deletePendingDashboard)
            Button("Abbrechen", role: .cancel) { dashboardPendingDeletion = nil }
        } message: {
            Text("Das Layout und alle Widgets dieses Dashboards werden entfernt.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "telemetry.csv"
        ) { _ in }
        .task(id: autoRefreshSeconds) {
            await runAutoRefresh()
        }
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            Picker("Dashboard", selection: selectedDashboardBinding) {
                ForEach(store.dashboards) { dashboard in
                    Text(dashboard.name).tag(Optional(dashboard.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 180, maxWidth: 280)
            .accessibilityLabel("Dashboard")

            Menu {
                Button("Neues Dashboard", systemImage: "plus", action: beginNewDashboard)
                Button("Dashboard umbenennen", systemImage: "pencil", action: beginRenameDashboard)
                    .disabled(store.currentDashboard == nil)
                Divider()
                Button("Dashboard löschen", systemImage: "trash", role: .destructive, action: confirmDashboardDeletion)
                    .disabled(store.dashboards.count <= 1)
            } label: {
                Label("Dashboards verwalten", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .help("Dashboards verwalten")

            Divider().frame(height: 22)

            Button("Widget hinzufügen", systemImage: "plus.rectangle.on.rectangle", action: beginAddWidget)

            Spacer()

            Picker("Automatisch aktualisieren", selection: $autoRefreshSeconds) {
                Text("Auto: Aus").tag(0)
                Text("Auto: 10 s").tag(10)
                Text("Auto: 30 s").tag(30)
                Text("Auto: 60 s").tag(60)
            }
            .frame(width: 125)

            Button("Aktualisieren", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .help("Alle Widgets aktualisieren")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if let dashboard = store.currentDashboard, !dashboard.widgets.isEmpty {
            GeometryReader { geometry in
                let contentWidth = max(
                    TelemetryDashboardWidget.minimumWidth,
                    geometry.size.width - 24
                )
                ScrollView(.vertical) {
                    TelemetryDashboardFlowLayout(spacing: 12) {
                        ForEach(dashboard.widgets) { widget in
                            TelemetryDashboardWidgetCard(
                                widget: widget,
                                nodeNames: nodeNames,
                                loader: TelemetryDashboardDataLoader(database: database),
                                refreshToken: refreshToken,
                                onEdit: editWidget,
                                onRemove: removeWidget,
                                onDaysChanged: changeDays,
                                onExport: exportWidget
                            )
                            .frame(width: min(widget.width, contentWidth), height: widget.height)
                            .draggable(widget.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                handleDrop(items: items, targetID: widget.id)
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .padding(12)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Noch keine Widgets", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Füge ein Widget hinzu und wähle Metrik, Nodes und Zeitraum aus.")
            } actions: {
                Button("Widget hinzufügen", systemImage: "plus", action: beginAddWidget)
            }
        }
    }

    private var selectedDashboardBinding: Binding<UUID?> {
        Binding(
            get: { store.selectedDashboardID },
            set: { newValue in
                if let newValue { store.selectDashboard(id: newValue) }
            }
        )
    }

    private var dashboardNameAlertBinding: Binding<Bool> {
        Binding(
            get: { dashboardAction != nil },
            set: { if !$0 { dashboardAction = nil } }
        )
    }

    private var dashboardDeletionBinding: Binding<Bool> {
        Binding(
            get: { dashboardPendingDeletion != nil },
            set: { if !$0 { dashboardPendingDeletion = nil } }
        )
    }

    private func beginAddWidget() {
        editorRequest = TelemetryWidgetEditorRequest(mode: .add)
    }

    private func editWidget(_ widget: TelemetryDashboardWidget) {
        editorRequest = TelemetryWidgetEditorRequest(mode: .edit(widget))
    }

    private func saveWidget(_ widget: TelemetryDashboardWidget, isNew: Bool) {
        if isNew {
            store.addWidget(widget)
        } else {
            store.updateWidget(widget)
        }
        refresh()
    }

    private func removeWidget(_ widget: TelemetryDashboardWidget) {
        store.removeWidget(id: widget.id)
    }

    private func changeDays(_ days: Int, widget: TelemetryDashboardWidget) {
        store.updateDays(days, widgetID: widget.id)
        refresh()
    }

    private func handleDrop(items: [String], targetID: UUID) -> Bool {
        guard let source = items.first.flatMap(UUID.init(uuidString:)), source != targetID else {
            return false
        }
        store.reorderWidget(sourceID: source, before: targetID)
        return true
    }

    private func refresh() {
        refreshToken &+= 1
    }

    private func runAutoRefresh() async {
        guard autoRefreshSeconds > 0 else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(autoRefreshSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func exportWidget(
        _ widget: TelemetryDashboardWidget,
        snapshot: TelemetryDashboardSnapshot
    ) {
        let loader = TelemetryDashboardDataLoader(database: database)
        exportDocument = TelemetryCSVDocument(
            text: loader.csv(widget: widget, snapshot: snapshot, nodeNames: nodeNames)
        )
        isExporting = true
    }

    private func beginNewDashboard() {
        dashboardName = String(localized: "New Dashboard")
        dashboardAction = .create
    }

    private func beginRenameDashboard() {
        guard let dashboard = store.currentDashboard else { return }
        dashboardName = dashboard.name
        dashboardAction = .rename(dashboard.id)
    }

    private func commitDashboardName() {
        let name = dashboardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let action = dashboardAction else { return }
        switch action {
        case .create: store.addDashboard(named: name)
        case .rename(let id): store.renameDashboard(id: id, to: name)
        }
        dashboardAction = nil
    }

    private func confirmDashboardDeletion() {
        guard store.dashboards.count > 1 else { return }
        dashboardPendingDeletion = store.currentDashboard
    }

    private func deletePendingDashboard() {
        if let dashboardPendingDeletion { store.deleteDashboard(id: dashboardPendingDeletion.id) }
        dashboardPendingDeletion = nil
    }
}

private enum DashboardNameAction {
    case create
    case rename(UUID)

    var title: String {
        switch self {
        case .create: return String(localized: "New Dashboard")
        case .rename: return String(localized: "Rename Dashboard")
        }
    }
}

struct TelemetryWidgetEditorRequest: Identifiable {
    enum Mode {
        case add
        case edit(TelemetryDashboardWidget)
    }

    let id = UUID()
    let mode: Mode
}

private struct TelemetryWidgetEditor: View {
    @Environment(\.dismiss) private var dismiss

    let request: TelemetryWidgetEditorRequest
    let nodeNames: [UInt32: String]
    let onSave: (TelemetryDashboardWidget, Bool) -> Void

    @State private var draft: TelemetryDashboardWidget
    @State private var thresholdText: String
    @State private var nodeSearch = ""

    private let dayOptions = [1, 7, 14, 30, 0]

    init(
        request: TelemetryWidgetEditorRequest,
        nodeNames: [UInt32: String],
        onSave: @escaping (TelemetryDashboardWidget, Bool) -> Void
    ) {
        self.request = request
        self.nodeNames = nodeNames
        self.onSave = onSave
        let initial: TelemetryDashboardWidget
        switch request.mode {
        case .add:
            initial = TelemetryDashboardWidget(nodeIds: nodeNames.keys.sorted())
        case .edit(let widget):
            initial = widget
        }
        _draft = State(initialValue: initial)
        _thresholdText = State(
            initialValue: initial.threshold.map { String(format: "%.4g", $0) } ?? ""
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? String(localized: "Add Widget") : String(localized: "Edit Widget"))
                    .font(.title2.bold())
                Spacer()
            }
            .padding()
            Divider()

            Form {
                Picker("Widget-Typ", selection: $draft.type) {
                    ForEach(TelemetryDashboardWidgetType.allCases) { type in
                        Label(type.displayName, systemImage: type.systemImage).tag(type)
                    }
                }

                if draft.type.usesMetric {
                    Picker("Metrik", selection: $draft.metric) {
                        Section("Windows-Dashboard") {
                            ForEach(TelemetrySeriesMetric.windowsDashboardMetrics) { metric in
                                Text(metricLabel(metric)).tag(metric)
                            }
                        }
                        Section("Weitere Meshtastic-Telemetrie") {
                            ForEach(advancedMetrics) { metric in
                                Text(metricLabel(metric)).tag(metric)
                            }
                        }
                    }
                }

                if draft.type != .clock {
                    Section("Nodes") {
                        TextField("Nodes filtern", text: $nodeSearch)
                        if filteredNodes.isEmpty {
                            Text("Keine passenden Nodes")
                                .foregroundStyle(.secondary)
                        } else {
                            List(filteredNodes, id: \.id) { node in
                                Button {
                                    toggleNode(node.id)
                                } label: {
                                    HStack {
                                        Image(systemName: draft.nodeIds.contains(node.id)
                                            ? "checkmark.circle.fill"
                                            : "circle")
                                            .foregroundStyle(draft.nodeIds.contains(node.id)
                                                ? Color.accentColor
                                                : Color.secondary)
                                        Text(node.name)
                                        Spacer()
                                        Text("!\(String(node.id, radix: 16))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(minHeight: 130, maxHeight: 190)
                        }
                        Text(nodeHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.type != .clock {
                    Picker("Zeitraum", selection: $draft.days) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text(
                                days == 0
                                    ? String(localized: "All")
                                    : String(localized: "\(days) Days")
                            )
                            .tag(days)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                TextField("Titel", text: $draft.title)

                Section("Kachelgröße") {
                    Stepper(
                        "Breite: \(Int(draft.width)) pt",
                        value: $draft.width,
                        in: TelemetryDashboardWidget.minimumWidth...900,
                        step: 20
                    )
                    Stepper(
                        "Höhe: \(Int(draft.height)) pt",
                        value: $draft.height,
                        in: TelemetryDashboardWidget.minimumHeight...700,
                        step: 20
                    )
                }

                if draft.type.supportsChartOptions {
                    Section("Diagrammoptionen") {
                        TextField("Schwellwert (leer = aus)", text: $thresholdText)
                        Toggle("Gleitenden Mittelwert anzeigen", isOn: $draft.showMovingAverage)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 620)
        .onChange(of: draft.type) { _, newValue in
            if !newValue.allowsMultipleNodes, let first = draft.nodeIds.first {
                draft.nodeIds = [first]
            }
            if !newValue.supportsChartOptions { draft.showMovingAverage = false }
        }
    }

    private var isNew: Bool {
        if case .add = request.mode { return true }
        return false
    }

    private var filteredNodes: [(id: UInt32, name: String)] {
        let query = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return nodeNames
            .map { (id: $0.key, name: $0.value) }
            .filter { node in
                query.isEmpty || node.name.lowercased().contains(query)
                    || String(node.id, radix: 16).contains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var advancedMetrics: [TelemetrySeriesMetric] {
        let primary = Set(TelemetrySeriesMetric.windowsDashboardMetrics)
        return TelemetrySeriesMetric.allCases.filter { !primary.contains($0) }
    }

    private var nodeHint: String {
        if draft.type.allowsMultipleNodes {
            return draft.nodeIds.isEmpty
                ? String(localized: "No selection means all known nodes.")
                : String(localized: "Multiple selection is available.")
        }
        return String(localized: "Exactly one node can be selected for this widget type.")
    }

    private var canSave: Bool {
        draft.type == .clock || draft.type.allowsMultipleNodes || !draft.nodeIds.isEmpty
    }

    private func metricLabel(_ metric: TelemetrySeriesMetric) -> String {
        metric.unit.isEmpty ? metric.displayName : "\(metric.displayName) (\(metric.unit))"
    }

    private func toggleNode(_ nodeId: UInt32) {
        if draft.nodeIds.contains(nodeId) {
            draft.nodeIds.removeAll { $0 == nodeId }
        } else if draft.type.allowsMultipleNodes {
            draft.nodeIds.append(nodeId)
            draft.nodeIds.sort()
        } else {
            draft.nodeIds = [nodeId]
        }
    }

    private func save() {
        let normalizedThreshold = thresholdText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        draft.threshold = normalizedThreshold.isEmpty ? nil : Double(normalizedThreshold)
        draft.normalize()
        onSave(draft, isNew)
        dismiss()
    }
}

private struct TelemetryDashboardFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: nil),
            subviews: subviews
        )
        for item in result.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let availableWidth = proposal.width ?? subviews.reduce(0) {
            $0 + $1.sizeThatFits(.unspecified).width + spacing
        }
        var items: [LayoutItem] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maximumWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(LayoutItem(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maximumWidth = max(maximumWidth, x - spacing)
        }
        return LayoutResult(
            items: items,
            size: CGSize(width: maximumWidth, height: y + rowHeight)
        )
    }

    private struct LayoutItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private struct LayoutResult {
        let items: [LayoutItem]
        let size: CGSize
    }
}

private struct TelemetryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        self.text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
