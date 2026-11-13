import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// Native MapKit map with online/offline raster tiles, native vector rendering,
/// node history, waypoints, direct-neighbor contacts, and traceroutes.
struct MapView: View {
    @Environment(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(AppCoordinator.self) private var coordinator
    @State private var settings = SettingsService.shared
    @State private var offlineManager = OfflineMapManager()
    @State private var emergencyStore = EmergencyFeatureStore()
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50.9, longitude: 9.5),
        span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)
    )
    @State private var currentZoom = 10
    @State private var showNodeInfo: NodeInfo?
    @State private var tracerouteTarget: NodeInfo?
    @State private var telemetryTarget: NodeInfo?
    @State private var remoteAdminTarget: NodeInfo?
    @State private var showWaypointInfo: MeshWaypoint?
    @State private var waypointDraft: WaypointCoordinateDraft?
    @State private var storedWaypoints: [UInt32: MeshWaypoint] = [:]
    @State private var hiddenWaypointIDs: Set<UInt32> = []
    @State private var pathNodeIds: Set<UInt32> = []
    @State private var showOfflineManager = false
    @State private var showLayerControls = false
    @State private var showTrackPicker = false
    @State private var showWaypoints = true
    @State private var showNeighbors = false
    @State private var showNeighborsPermanently = false
    @State private var neighborColorMode = NeighborLineColorMode.signalQuality
    @State private var showTraceroutes = false
    @State private var persistedDirectContacts: [DirectNeighborContact] = []
    @State private var directContactLoadGeneration = 0
    @State private var tracerouteSelection = TracerouteMapSelectionStore.shared
    @State private var errorMessage: String?
    @State private var showEnvironmentControls = false
    @State private var environmentOverlay: EnvironmentOverlay?
    @State private var environmentRevision = 0
    @State private var environmentTrigger = 0
    @State private var environmentLastRefresh = Date.distantPast
    @State private var environmentRefreshScheduled = false

    /// Minimum interval between refreshes caused by incoming telemetry.
    private static let environmentRefreshThrottle: TimeInterval = 30

    private var runtimeConfiguration: MapRuntimeConfiguration {
        MapRuntimeConfiguration(settings: settings)
    }

    private var waypoints: [MeshWaypoint] {
        var merged = storedWaypoints
        for (id, waypoint) in coordinator.protocol_.waypoints {
            merged[id] = waypoint
        }
        return merged.values
            .filter { !hiddenWaypointIDs.contains($0.id) && !$0.isExpired }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var ownCoordinate: MapPointCoordinate? {
        guard let value = appState.effectiveOwnCoordinate() else { return nil }
        return .init(latitude: value.latitude, longitude: value.longitude)
    }

    private var directContacts: [DirectNeighborContact] {
        coordinator.protocol_.directNeighborContacts + persistedDirectContacts
    }

    private var displayedTraceroutes: [TracerouteResult] {
        if !tracerouteSelection.results.isEmpty { return tracerouteSelection.results }
        return Array(coordinator.tracerouteResults.prefix(10))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if runtimeConfiguration.effectiveRenderMode == .vector {
                VectorMeshMapViewRepresentable(
                    region: $region,
                    currentZoom: $currentZoom,
                    configuration: runtimeConfiguration,
                    nodes: appState.filteredNodes,
                    waypoints: showWaypoints ? waypoints : [],
                    emergencyFeatures: settings.mapOverlays.contains(.emergency) ? emergencyStore.features : [],
                    directContacts: directContacts,
                    traceroutes: displayedTraceroutes,
                    ownCoordinate: ownCoordinate,
                    focusNodeId: appState.mapFocusNodeId,
                    appState: appState,
                    pathNodeIds: pathNodeIds,
                    positionHistoryHours: settings.positionHistoryHours,
                    showNeighbors: showNeighbors,
                    showNeighborsPermanently: showNeighborsPermanently,
                    neighborColorMode: neighborColorMode,
                    showTraceroutes: showTraceroutes,
                    emergencyOverlayEnabled: settings.mapOverlays.contains(.emergency),
                    environmentOverlay: environmentOverlay,
                    onSendDM: openDirectMessage,
                    onShowNodeInfo: showNode,
                    onToggleFavorite: toggleFavorite,
                    onTogglePin: togglePin,
                    onTraceroute: showTraceroute,
                    onTelemetry: showTelemetry,
                    onRemoteAdmin: showRemoteAdmin,
                    onRequestInfo: requestInfo,
                    onTogglePath: togglePath,
                    onSetOwnPosition: setOwnPosition,
                    onCreateWaypoint: { coordinate in
                        waypointDraft = .init(coordinate: coordinate)
                    },
                    onShowWaypoint: showWaypoint,
                    onDeleteWaypoint: deleteWaypoint,
                    onVisibleRegionChanged: updateVisibleRegion,
                    onError: { errorMessage = $0 }
                )
            } else {
                MeshMapViewRepresentable(
                    region: $region,
                    currentZoom: $currentZoom,
                    configuration: runtimeConfiguration,
                    packageDirectories: offlineManager.packageDirectories,
                    liveCacheDirectory: offlineManager.liveCacheDirectory,
                    nodes: appState.filteredNodes,
                    waypoints: showWaypoints ? waypoints : [],
                    emergencyFeatures: settings.mapOverlays.contains(.emergency) ? emergencyStore.features : [],
                    directContacts: directContacts,
                    traceroutes: displayedTraceroutes,
                    ownCoordinate: ownCoordinate,
                    focusNodeId: appState.mapFocusNodeId,
                    appState: appState,
                    pathNodeIds: pathNodeIds,
                    positionHistoryHours: settings.positionHistoryHours,
                    showNeighbors: showNeighbors,
                    showNeighborsPermanently: showNeighborsPermanently,
                    neighborColorMode: neighborColorMode,
                    showTraceroutes: showTraceroutes,
                    environmentOverlay: environmentOverlay,
                    onSendDM: openDirectMessage,
                    onShowNodeInfo: showNode,
                    onToggleFavorite: toggleFavorite,
                    onTogglePin: togglePin,
                    onTraceroute: showTraceroute,
                    onTelemetry: showTelemetry,
                    onRemoteAdmin: showRemoteAdmin,
                    onRequestInfo: requestInfo,
                    onTogglePath: togglePath,
                    onSetOwnPosition: setOwnPosition,
                    onCreateWaypoint: { coordinate in
                        waypointDraft = .init(coordinate: coordinate)
                    },
                    onShowWaypoint: showWaypoint,
                    onDeleteWaypoint: deleteWaypoint,
                    onVisibleRegionChanged: updateVisibleRegion
                )
            }

            MapControlBar(
                settings: settings,
                currentZoom: currentZoom,
                effectiveRenderMode: runtimeConfiguration.effectiveRenderMode,
                onShowLayers: { showLayerControls.toggle() },
                onShowEnvironment: { showEnvironmentControls.toggle() },
                onShowOfflineMaps: { showOfflineManager = true }
            )
            .padding(10)
            .popover(isPresented: $showEnvironmentControls, arrowEdge: .top) {
                EnvironmentMapControls(settings: settings, overlay: environmentOverlay)
            }
            .popover(isPresented: $showLayerControls, arrowEdge: .top) {
                MapLayerControls(
                    settings: settings,
                    showWaypoints: $showWaypoints,
                    showNeighbors: $showNeighbors,
                    showNeighborsPermanently: $showNeighborsPermanently,
                    neighborColorMode: $neighborColorMode,
                    showTraceroutes: $showTraceroutes,
                    selectedTraceroutes: tracerouteSelection.results,
                    pathCount: pathNodeIds.count,
                    emergencyFeatureCount: emergencyStore.features.count,
                    emergencyIsLoading: emergencyStore.isLoading,
                    onRemoveTraceroute: { id in
                        tracerouteSelection.remove(ids: [id])
                    },
                    onClearTraceroutes: tracerouteSelection.clear,
                    onChooseTracks: { showTrackPicker = true },
                    onClearTracks: { pathNodeIds.removeAll() }
                )
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let legend = environmentOverlay?.surface?.legend {
                            EnvironmentLegendView(legend: legend)
                                .padding(7)
                                .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
                        }
                        MapAttributionView(
                            text: runtimeConfiguration.attribution,
                            includesEmergencyLayer: settings.mapOverlays.contains(.emergency)
                        )
                    }
                    Spacer()
                    if showNeighbors {
                        NeighborLegend(mode: neighborColorMode)
                    }
                }
                .padding(10)
            }
            .allowsHitTesting(true)
        }
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
        .sheet(item: $showWaypointInfo) { waypoint in
            WaypointDetailSheet(waypoint: waypoint)
        }
        .sheet(item: $waypointDraft) { draft in
            WaypointEditorSheet(
                coordinate: draft.coordinate,
                sourceNodeId: coordinator.protocol_.currentNodeId,
                onSave: saveWaypoint
            )
        }
        .sheet(isPresented: $showOfflineManager) {
            OfflineMapManagerView(manager: offlineManager)
        }
        .sheet(isPresented: $showTrackPicker) {
            NodeTrackPickerView(
                nodes: appState.filteredNodes,
                selectedNodeIDs: $pathNodeIds
            )
        }
        .task {
            await offlineManager.refresh()
            await loadStoredWaypoints()
            persistProtocolWaypoints(coordinator.protocol_.waypoints)
            await loadPersistedDirectContacts()
        }
        .onChange(of: coordinator.protocol_.waypoints) { _, newValue in
            persistProtocolWaypoints(newValue)
        }
        .onChange(of: appState.mapFocusNodeId) { _, newValue in
            focus(on: newValue)
        }
        .onChange(of: appState.mapPathToggleNodeId) { _, nodeID in
            guard let nodeID else { return }
            togglePath(nodeID)
            appState.mapPathToggleNodeId = nil
        }
        .onChange(of: tracerouteSelection.results) { _, results in
            if !results.isEmpty { showTraceroutes = true }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .telemetryDatabaseDidClear,
            object: TelemetryDatabaseService.shared
        )) { _ in
            directContactLoadGeneration &+= 1
            let generation = directContactLoadGeneration
            persistedDirectContacts = []
            Task { await loadPersistedDirectContacts(generation: generation) }
            if settings.showEnvironmentData { environmentTrigger &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .telemetrySampleDidInsert,
            object: TelemetryDatabaseService.shared
        )) { notification in
            scheduleEnvironmentRefresh(after: notification)
        }
        .task(id: environmentRefreshKey) {
            await refreshEnvironmentOverlay()
        }
        .alert("Map Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Environment overlay

    /// Everything that requires an immediate recompute. While the overlay is off only the
    /// switch itself is read, so no environment work happens on map updates.
    private var environmentRefreshKey: EnvironmentRefreshKey {
        guard settings.showEnvironmentData else { return .off }
        return EnvironmentRefreshKey(
            enabled: true,
            metricKey: settings.environmentMetricKey,
            boxMode: settings.environmentBoxMode,
            showHeatmap: settings.environmentShowHeatmap,
            excludedNodeIds: settings.environmentExcludedNodeIds,
            radiationInSievert: settings.radiationInSievert,
            positionedNodeIds: Set(appState.filteredNodes.compactMap { $0.latitude != nil ? $0.id : nil }),
            trigger: environmentTrigger
        )
    }

    /// New telemetry for a shown metric refreshes the overlay at most once per 30 s.
    private func scheduleEnvironmentRefresh(after notification: Notification) {
        guard settings.showEnvironmentData, !environmentRefreshScheduled else { return }
        let metrics = notification.userInfo?[TelemetryDatabaseService.insertedMetricsUserInfoKey] as? [String] ?? []
        let selected = settings.environmentMetric.column
        let relevant = metrics.contains { metric in
            (settings.environmentShowHeatmap && metric == selected)
                || (settings.environmentBoxMode != .off && EnvironmentMetricInfo.isKnownColumn(metric))
        }
        guard relevant else { return }

        environmentRefreshScheduled = true
        let delay = max(0, Self.environmentRefreshThrottle - Date().timeIntervalSince(environmentLastRefresh))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            environmentRefreshScheduled = false
            environmentTrigger &+= 1
        }
    }

    private func refreshEnvironmentOverlay() async {
        guard settings.showEnvironmentData else {
            environmentOverlay = nil
            return
        }
        // Debounce bursts of selection changes.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        environmentLastRefresh = Date()

        let options = EnvironmentOverlayBuilder.Options(
            metric: settings.environmentMetric,
            boxMode: settings.environmentBoxMode,
            showHeatmap: settings.environmentShowHeatmap,
            excludedNodeIds: settings.environmentExcludedNodeIds,
            radiationInSievert: settings.radiationInSievert,
            now: Date()
        )
        let nodes = appState.filteredNodes.compactMap { node -> EnvironmentNodePosition? in
            guard let latitude = node.latitude, let longitude = node.longitude else { return nil }
            return EnvironmentNodePosition(
                nodeId: node.id,
                latitude: latitude,
                longitude: longitude,
                title: node.shortName.isEmpty ? node.nodeId : node.shortName
            )
        }
        let readings = await TelemetryDatabaseService.shared.latestEnvironmentPerNode(
            metricColumn: options.showHeatmap ? options.metric.column : nil,
            maxAgeHours: EnvironmentOverlayBuilder.historyHours
        )
        guard !Task.isCancelled else { return }

        environmentRevision &+= 1
        let revision = environmentRevision
        let overlay = await Task.detached(priority: .utility) {
            EnvironmentOverlayBuilder.build(revision: revision, nodes: nodes, readings: readings, options: options)
        }.value
        guard !Task.isCancelled, settings.showEnvironmentData else { return }
        environmentOverlay = overlay
    }

    // MARK: - Actions

    private func loadPersistedDirectContacts() async {
        directContactLoadGeneration &+= 1
        await loadPersistedDirectContacts(generation: directContactLoadGeneration)
    }

    private func loadPersistedDirectContacts(generation: Int) async {
        let contacts = await Task.detached(priority: .utility) {
            TelemetryDatabaseService.shared.getDirectNeighborContacts()
        }.value
        guard !Task.isCancelled, directContactLoadGeneration == generation else { return }
        persistedDirectContacts = contacts
    }

    private func openDirectMessage(_ nodeId: UInt32) {
        coordinator.openDirectMessage(nodeId: nodeId, openWindow: openWindow)
    }

    private func showNode(_ nodeId: UInt32) {
        showNodeInfo = appState.node(forId: nodeId)
    }

    private func toggleFavorite(_ nodeId: UInt32) {
        guard let node = appState.node(forId: nodeId) else { return }
        Task { _ = await coordinator.protocol_.setFavorite(!node.isFavorite, nodeId: nodeId) }
    }

    private func togglePin(_ nodeId: UInt32) {
        guard let node = appState.node(forId: nodeId) else { return }
        node.isPinned.toggle()
        coordinator.coreDataStore.updateNodePinState(nodeId: nodeId, isPinned: node.isPinned)
    }

    private func showTraceroute(_ nodeId: UInt32) {
        tracerouteTarget = appState.node(forId: nodeId)
    }

    private func showTelemetry(_ nodeId: UInt32) {
        telemetryTarget = appState.node(forId: nodeId)
    }

    private func showRemoteAdmin(_ nodeId: UInt32) {
        remoteAdminTarget = appState.node(forId: nodeId)
    }

    private func requestInfo(_ request: NodeInfoRequestType, from nodeId: UInt32) {
        Task { _ = await coordinator.protocol_.requestNodeInfo(request, from: nodeId) }
    }

    private func setOwnPosition(_ coordinate: CLLocationCoordinate2D) {
        settings.myLatitude = coordinate.latitude
        settings.myLongitude = coordinate.longitude
        appState.recalculateAllDistances()
    }

    private func togglePath(_ nodeId: UInt32) {
        if pathNodeIds.contains(nodeId) {
            pathNodeIds.remove(nodeId)
        } else {
            pathNodeIds.insert(nodeId)
        }
    }

    private func showWaypoint(_ id: UInt32) {
        showWaypointInfo = waypoints.first { $0.id == id }
    }

    private func saveWaypoint(_ waypoint: MeshWaypoint, sendToMesh: Bool) {
        storedWaypoints[waypoint.id] = waypoint
        hiddenWaypointIDs.remove(waypoint.id)
        Task {
            do {
                try await WaypointPersistenceService.shared.upsert(waypoint)
                if sendToMesh {
                    let sent = await coordinator.protocol_.sendWaypoint(
                        waypoint,
                        channelIndex: Int(waypoint.channelIndex)
                    )
                    if !sent {
                        errorMessage = String(localized: "The waypoint was saved locally but could not be sent to the mesh.")
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteWaypoint(_ id: UInt32, fromMesh: Bool) {
        guard let waypoint = waypoints.first(where: { $0.id == id }) else { return }
        hiddenWaypointIDs.insert(id)
        storedWaypoints.removeValue(forKey: id)
        Task {
            do {
                try await WaypointPersistenceService.shared.delete(id: id)
                if fromMesh {
                    let sent = await coordinator.protocol_.deleteWaypoint(
                        id: id,
                        lockedTo: waypoint.lockedTo,
                        channelIndex: Int(waypoint.channelIndex)
                    )
                    if !sent {
                        errorMessage = String(localized: "The waypoint was removed locally but could not be deleted from the mesh.")
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateVisibleRegion(_ bounds: MapBounds, _ zoom: Int) {
        emergencyStore.refresh(
            bounds: bounds,
            zoom: zoom,
            enabled: settings.mapOverlays.contains(.emergency)
        )
    }

    private func focus(on nodeId: UInt32?) {
        if let nodeId,
           let node = appState.nodes[nodeId],
           let latitude = node.latitude,
           let longitude = node.longitude {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        guard nodeId != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            appState.mapFocusNodeId = nil
        }
    }

    private func loadStoredWaypoints() async {
        do {
            storedWaypoints = try await WaypointPersistenceService.shared.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistProtocolWaypoints(_ received: [UInt32: MeshWaypoint]) {
        guard !received.isEmpty else { return }
        for (id, waypoint) in received {
            storedWaypoints[id] = waypoint
            hiddenWaypointIDs.remove(id)
        }
        let snapshot = storedWaypoints
        Task {
            do {
                try await WaypointPersistenceService.shared.replace(with: snapshot)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

// MARK: - Runtime configuration

struct MapRuntimeConfiguration: Equatable {
    let mode: MapMode
    let requestedRenderMode: MapRenderMode
    let source: MapTileSource
    let descriptor: MapTileSourceDescriptor
    let vectorStyleURL: String

    init(settings: SettingsService) {
        mode = settings.mapMode
        requestedRenderMode = settings.mapRenderMode
        source = MapTileSource(style: settings.meshMapStyle)

        descriptor = Self.rasterDescriptor(mode: mode, source: source, settings: settings)
        vectorStyleURL = Self.vectorStyleURL(mode: mode, source: source, settings: settings)
    }

    /// Raster tile source for a map mode. Offline mode fills its cache from the
    /// Mesh Hessen server (Windows parity); custom URLs apply only in custom mode.
    static func rasterDescriptor(
        mode: MapMode,
        source: MapTileSource,
        settings: SettingsService
    ) -> MapTileSourceDescriptor {
        switch mode {
        case .meshHessen, .offline:
            return .init(source: source, urlTemplate: source.meshHessenRasterURLTemplate)
        case .publicOpenStreetMap:
            return .init(source: .osm, urlTemplate: settings.publicOSMTileURL)
        case .custom:
            let template: String
            switch source {
            case .osm: template = settings.osmTileURL
            case .topographic: template = settings.topographicTileURL
            case .dark: template = settings.darkTileURL
            }
            return .init(source: source, urlTemplate: template)
        }
    }

    /// Vector style URL for a map mode, following the same rules as `rasterDescriptor`.
    static func vectorStyleURL(mode: MapMode, source: MapTileSource, settings: SettingsService) -> String {
        if mode == .meshHessen || mode == .offline {
            return source.meshHessenVectorStyleURL
        }
        switch source {
        case .osm: return settings.vectorStyleOSMURL
        case .topographic: return settings.vectorStyleTopographicURL
        case .dark: return settings.vectorStyleDarkURL
        }
    }

    var effectiveRenderMode: MapRenderMode {
        if mode == .publicOpenStreetMap { return .raster }
        return requestedRenderMode
    }

    var usesRasterOverlay: Bool { effectiveRenderMode == .raster }
    var offlineOnly: Bool { mode == .offline }

    var attribution: String {
        if effectiveRenderMode == .vector {
            return "© OpenMapTiles © OpenStreetMap contributors"
        }
        return descriptor.attribution
    }

    var preferredConfiguration: MKMapConfiguration {
        let elevation: MKMapConfiguration.ElevationStyle = source == .topographic ? .realistic : .flat
        let configuration = MKStandardMapConfiguration(elevationStyle: elevation)
        configuration.emphasisStyle = source == .dark ? .muted : .default
        return configuration
    }
}

struct MapPointCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    var coreLocationCoordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

func resolvedTracerouteHopCoordinate(
    _ hop: TracerouteHop,
    nodes: [NodeInfo]
) -> MapPointCoordinate? {
    guard !hop.isUnknown else { return nil }
    if let position = hop.resolvedPosition(fallbackLatitude: nil, fallbackLongitude: nil) {
        return MapPointCoordinate(latitude: position.latitude, longitude: position.longitude)
    }
    let node = nodes.first { $0.id == hop.nodeId }
    if let latitude = node?.latitude, let longitude = node?.longitude {
        return MapPointCoordinate(latitude: latitude, longitude: longitude)
    }
    let loggedPosition = LocationLogger.shared.readPositions(for: hop.nodeId).last
    guard let position = hop.resolvedPosition(
        fallbackLatitude: loggedPosition?.latitude,
        fallbackLongitude: loggedPosition?.longitude
    ) else { return nil }
    return MapPointCoordinate(latitude: position.latitude, longitude: position.longitude)
}

func resolvedTracerouteSourceCoordinate(
    _ traceroute: TracerouteResult,
    ownCoordinate: MapPointCoordinate?,
    nodes: [NodeInfo]
) -> MapPointCoordinate? {
    if let latitude = traceroute.sourceLatitude, let longitude = traceroute.sourceLongitude {
        return MapPointCoordinate(latitude: latitude, longitude: longitude)
    }
    if let ownCoordinate { return ownCoordinate }
    guard let sourceNodeId = traceroute.sourceNodeId,
          sourceNodeId != 0,
          sourceNodeId != TracerouteHop.unknownNodeId else { return nil }
    let sourceNode = nodes.first { $0.id == sourceNodeId }
    let loggedPosition = LocationLogger.shared.readPositions(for: sourceNodeId).last
    guard let latitude = sourceNode?.latitude ?? loggedPosition?.latitude,
          let longitude = sourceNode?.longitude ?? loggedPosition?.longitude else { return nil }
    return MapPointCoordinate(latitude: latitude, longitude: longitude)
}

private struct EnvironmentRefreshKey: Equatable {
    var enabled: Bool
    var metricKey: String
    var boxMode: EnvironmentBoxMode
    var showHeatmap: Bool
    var excludedNodeIds: Set<UInt32>
    var radiationInSievert: Bool
    var positionedNodeIds: Set<UInt32>
    var trigger: Int

    static let off = EnvironmentRefreshKey(
        enabled: false,
        metricKey: "",
        boxMode: .off,
        showHeatmap: false,
        excludedNodeIds: [],
        radiationInSievert: false,
        positionedNodeIds: [],
        trigger: 0
    )
}

private struct WaypointCoordinateDraft: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Map controls

private struct MapControlBar: View {
    @Bindable var settings: SettingsService
    let currentZoom: Int
    let effectiveRenderMode: MapRenderMode
    let onShowLayers: () -> Void
    let onShowEnvironment: () -> Void
    let onShowOfflineMaps: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Z\(currentZoom)")
                .font(.caption.monospacedDigit())

            Menu {
                Picker("Renderer", selection: $settings.mapRenderMode) {
                    ForEach(MapRenderMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
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
            } label: {
                Label(
                    "\(settings.meshMapStyle.localizedName) · \(effectiveRenderMode.localizedName)",
                    systemImage: "map"
                )
            }
            .menuStyle(.borderlessButton)

            Button("Layers", systemImage: "square.3.layers.3d", action: onShowLayers)
                .labelStyle(.iconOnly)
                .help("Map Layers")
            Button("Environment Data", systemImage: "thermometer.medium", action: onShowEnvironment)
                .labelStyle(.iconOnly)
                .symbolVariant(settings.showEnvironmentData ? .fill : .none)
                .help("Environment data on the map: value boxes, heatmap, metric and node selection")
            Button("Offline Maps", systemImage: "arrow.down.circle", action: onShowOfflineMaps)
                .labelStyle(.iconOnly)
                .help("Offline Maps")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct MapLayerControls: View {
    @Bindable var settings: SettingsService
    @Binding var showWaypoints: Bool
    @Binding var showNeighbors: Bool
    @Binding var showNeighborsPermanently: Bool
    @Binding var neighborColorMode: NeighborLineColorMode
    @Binding var showTraceroutes: Bool
    let selectedTraceroutes: [TracerouteResult]
    let pathCount: Int
    let emergencyFeatureCount: Int
    let emergencyIsLoading: Bool
    let onRemoveTraceroute: (UUID) -> Void
    let onClearTraceroutes: () -> Void
    let onChooseTracks: () -> Void
    let onClearTracks: () -> Void

    var body: some View {
        Form {
            Section("Mesh Layers") {
                Toggle("Waypoints", isOn: $showWaypoints)
                Toggle("Direct Neighbors", isOn: $showNeighbors)
                if showNeighbors {
                    Toggle("Keep older contacts", isOn: $showNeighborsPermanently)
                    Picker("Neighbor colors", selection: $neighborColorMode) {
                        ForEach(NeighborLineColorMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
                Toggle("Traceroutes", isOn: $showTraceroutes)
                if !selectedTraceroutes.isEmpty {
                    ForEach(selectedTraceroutes) { traceroute in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(traceroute.targetName)
                                    .lineLimit(1)
                                Text(traceroute.receivedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                onRemoveTraceroute(traceroute.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove traceroute")
                        }
                    }
                    Button("Remove All Selected Traceroutes", role: .destructive, action: onClearTraceroutes)
                }
            }

            Section("Tracks") {
                Button("Choose Node Tracks…", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: onChooseTracks)
                if pathCount > 0 {
                    Button("Hide All \(pathCount) Tracks", role: .destructive, action: onClearTracks)
                }
            }

            Section("Public Safety") {
                Toggle("Fire and Rescue", isOn: emergencyBinding)
                if emergencyIsLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if settings.mapOverlays.contains(.emergency) {
                    Text("\(emergencyFeatureCount) features in the visible area")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 340)
    }

    private var emergencyBinding: Binding<Bool> {
        Binding(
            get: { settings.mapOverlays.contains(.emergency) },
            set: { enabled in
                var overlays = settings.mapOverlays
                if enabled { overlays.insert(.emergency) } else { overlays.remove(.emergency) }
                settings.mapOverlays = overlays
            }
        )
    }
}

private struct NodeTrackPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let nodes: [NodeInfo]
    @Binding var selectedNodeIDs: Set<UInt32>

    private var loggedNodes: [NodeInfo] {
        let ids = Set(LocationLogger.shared.allLoggedNodeIds())
        return nodes
            .filter { ids.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loggedNodes.isEmpty {
                    ContentUnavailableView(
                        "No Node Tracks",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text("Enable position logging to record node movement.")
                    )
                } else {
                    List(loggedNodes) { node in
                        Toggle(isOn: selectionBinding(for: node.id)) {
                            VStack(alignment: .leading) {
                                Text(node.name)
                                Text(node.nodeId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Node Tracks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func selectionBinding(for nodeId: UInt32) -> Binding<Bool> {
        Binding(
            get: { selectedNodeIDs.contains(nodeId) },
            set: { selected in
                if selected { selectedNodeIDs.insert(nodeId) } else { selectedNodeIDs.remove(nodeId) }
            }
        )
    }
}

private struct MapAttributionView: View {
    let text: String
    let includesEmergencyLayer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Link(destination: URL(string: "https://www.openstreetmap.org/copyright") ?? URL(fileURLWithPath: "/")) {
                Text(text)
            }
            if includesEmergencyLayer {
                Text("Fire & Rescue data © OpenStreetMap contributors")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 5))
    }
}

private struct NeighborLegend: View {
    let mode: NeighborLineColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(mode.displayName)
                .font(.caption.bold())
            switch mode {
            case .signalQuality:
                LinearGradient(colors: [.red, .yellow, .green], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120, height: 6)
                Text("−20 dB         +10 dB")
                    .font(.caption2.monospacedDigit())
            case .age:
                LinearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 120, height: 6)
                Text("now             24 h")
                    .font(.caption2.monospacedDigit())
            case .nodeColor:
                Text("Uses each node’s assigned color")
                    .font(.caption2)
            }
        }
        .padding(7)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
    }
}

// MARK: - MapKit bridge

private struct MeshMapViewRepresentable: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var currentZoom: Int
    let configuration: MapRuntimeConfiguration
    let packageDirectories: [URL]
    let liveCacheDirectory: URL?
    let nodes: [NodeInfo]
    let waypoints: [MeshWaypoint]
    let emergencyFeatures: [EmergencyMapFeature]
    let directContacts: [DirectNeighborContact]
    let traceroutes: [TracerouteResult]
    let ownCoordinate: MapPointCoordinate?
    var focusNodeId: UInt32?
    let appState: AppState
    let pathNodeIds: Set<UInt32>
    let positionHistoryHours: Int
    let showNeighbors: Bool
    let showNeighborsPermanently: Bool
    let neighborColorMode: NeighborLineColorMode
    let showTraceroutes: Bool
    var environmentOverlay: EnvironmentOverlay?
    let onSendDM: (UInt32) -> Void
    let onShowNodeInfo: (UInt32) -> Void
    let onToggleFavorite: (UInt32) -> Void
    let onTogglePin: (UInt32) -> Void
    let onTraceroute: (UInt32) -> Void
    let onTelemetry: (UInt32) -> Void
    let onRemoteAdmin: (UInt32) -> Void
    let onRequestInfo: (NodeInfoRequestType, UInt32) -> Void
    let onTogglePath: (UInt32) -> Void
    let onSetOwnPosition: (CLLocationCoordinate2D) -> Void
    let onCreateWaypoint: (CLLocationCoordinate2D) -> Void
    let onShowWaypoint: (UInt32) -> Void
    let onDeleteWaypoint: (UInt32, Bool) -> Void
    let onVisibleRegionChanged: (MapBounds, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(region, animated: false)
        map.isPitchEnabled = true
        map.showsCompass = true
        map.showsScale = true
        context.coordinator.applyBaseMap(to: map)

        let rightClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 0x2
        map.addGestureRecognizer(rightClick)
        map.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: context.coordinator,
            userInfo: nil
        ))
        context.coordinator.mapView = map
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateBaseMapIfNeeded(map)
        context.coordinator.updateAnnotations(map)
        context.coordinator.updateDynamicOverlays(map)
        context.coordinator.updateEnvironment(map)

        if let focusNodeId,
           let node = nodes.first(where: { $0.id == focusNodeId }),
           let latitude = node.latitude,
           let longitude = node.longitude {
            let focusRegion = MKCoordinateRegion(
                center: .init(latitude: latitude, longitude: longitude),
                span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            Task { @MainActor in
                map.setRegion(focusRegion, animated: true)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MeshMapViewRepresentable
        private var currentConfiguration: MapRuntimeConfiguration?
        private var currentPackages: [URL] = []
        private var currentCacheDirectory: URL?
        private var baseTileOverlay: CachingTileOverlay?
        weak var mapView: MKMapView?
        /// Revision of the environment overlay currently drawn; -1 = none.
        private var environmentRevision = -1
        private var environmentSurface: EnvironmentSurfaceOverlay?
        private var environmentBoxes: [UInt32: EnvironmentValueBox] = [:]
        private var environmentHoverNodeId: UInt32?

        init(_ parent: MeshMapViewRepresentable) {
            self.parent = parent
        }

        // MARK: Base map

        func updateBaseMapIfNeeded(_ map: MKMapView) {
            guard currentConfiguration != parent.configuration
                    || currentPackages != parent.packageDirectories
                    || currentCacheDirectory != parent.liveCacheDirectory else { return }
            applyBaseMap(to: map)
        }

        func applyBaseMap(to map: MKMapView) {
            if let baseTileOverlay {
                map.removeOverlay(baseTileOverlay)
                self.baseTileOverlay = nil
            }
            map.preferredConfiguration = parent.configuration.preferredConfiguration
            currentConfiguration = parent.configuration
            currentPackages = parent.packageDirectories
            currentCacheDirectory = parent.liveCacheDirectory

            guard parent.configuration.usesRasterOverlay else { return }
            let cache = parent.liveCacheDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("MeshHessen-TileCache", isDirectory: true)
            let overlay = CachingTileOverlay(
                configuration: .init(
                    descriptor: parent.configuration.descriptor,
                    liveCacheDirectory: cache,
                    offlinePackageDirectories: parent.packageDirectories,
                    offlineOnly: parent.configuration.offlineOnly
                )
            )
            overlay.canReplaceMapContent = true
            baseTileOverlay = overlay
            map.addOverlay(overlay, level: .aboveLabels)
            if let environmentSurface {
                // The new base layer was appended on top; put the heatmap back above it.
                map.removeOverlay(environmentSurface)
                insertEnvironmentSurface(environmentSurface, into: map)
            }
        }

        // MARK: Environment overlay

        /// Applies a new environment overlay revision: the heatmap as one image overlay directly
        /// above the base map (below all lines; annotations are always drawn above overlays) and
        /// the value boxes as annotations.
        func updateEnvironment(_ map: MKMapView) {
            let revision = parent.environmentOverlay?.revision ?? -1
            guard revision != environmentRevision else { return }
            environmentRevision = revision

            if let environmentSurface {
                map.removeOverlay(environmentSurface)
                self.environmentSurface = nil
            }
            if let surface = parent.environmentOverlay?.surface {
                let overlay = EnvironmentSurfaceOverlay(surface: surface)
                environmentSurface = overlay
                insertEnvironmentSurface(overlay, into: map)
            }

            let overlay = parent.environmentOverlay
            environmentBoxes = Dictionary(
                (overlay?.boxes ?? []).map { ($0.nodeId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            switch overlay?.boxMode ?? .off {
            case .off: showEnvironmentBoxes([], on: map)
            case .always: showEnvironmentBoxes(overlay?.boxes ?? [], on: map)
            case .hover:
                showEnvironmentBoxes(environmentHoverNodeId.flatMap { environmentBoxes[$0] }.map { [$0] } ?? [], on: map)
            }
        }

        private func insertEnvironmentSurface(_ overlay: EnvironmentSurfaceOverlay, into map: MKMapView) {
            if let baseTileOverlay, map.overlays.contains(where: { $0 === baseTileOverlay }) {
                map.insertOverlay(overlay, above: baseTileOverlay)
            } else {
                map.insertOverlay(overlay, at: 0, level: .aboveRoads)
            }
        }

        private func showEnvironmentBoxes(_ boxes: [EnvironmentValueBox], on map: MKMapView) {
            map.removeAnnotations(map.annotations.filter { $0 is EnvironmentBoxAnnotation })
            map.addAnnotations(boxes.map(EnvironmentBoxAnnotation.init(box:)))
        }

        /// Hover mode: shows only the box of the node pin under the mouse (within 22 pt).
        @objc func mouseMoved(with event: NSEvent) {
            guard parent.environmentOverlay?.boxMode == .hover, let map = mapView,
                  !environmentBoxes.isEmpty else { return }
            let point = map.convert(event.locationInWindow, from: nil)
            var hit: UInt32?
            var best: CGFloat = 22
            for box in environmentBoxes.values {
                let pin = map.convert(
                    CLLocationCoordinate2D(latitude: box.latitude, longitude: box.longitude),
                    toPointTo: map
                )
                let distance = hypot(pin.x - point.x, pin.y - point.y)
                if distance < best {
                    best = distance
                    hit = box.nodeId
                }
            }
            guard hit != environmentHoverNodeId else { return }
            environmentHoverNodeId = hit
            showEnvironmentBoxes(hit.flatMap { environmentBoxes[$0] }.map { [$0] } ?? [], on: map)
        }

        // MARK: Annotations

        func updateAnnotations(_ map: MKMapView) {
            updateNodeAnnotations(map)
            updateWaypointAnnotations(map)
            updateEmergencyAnnotations(map)
        }

        private func updateNodeAnnotations(_ map: MKMapView) {
            let existing = Dictionary(
                uniqueKeysWithValues: map.annotations.compactMap { annotation -> (UInt32, NodeAnnotation)? in
                    guard let annotation = annotation as? NodeAnnotation else { return nil }
                    return (annotation.nodeId, annotation)
                }
            )
            let visibleNodes = parent.nodes.filter { $0.latitude != nil && $0.longitude != nil }
            let newIDs = Set(visibleNodes.map(\.id))
            map.removeAnnotations(existing.compactMap { newIDs.contains($0.key) ? nil : $0.value })

            for node in visibleNodes {
                guard let latitude = node.latitude, let longitude = node.longitude else { continue }
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if let annotation = existing[node.id] {
                    annotation.coordinate = coordinate
                    annotation.title = node.name
                    annotation.colorHex = node.colorHex
                } else {
                    let annotation = NodeAnnotation(nodeId: node.id, coordinate: coordinate)
                    annotation.title = node.name
                    annotation.subtitle = node.nodeId
                    annotation.colorHex = node.colorHex
                    map.addAnnotation(annotation)
                }
            }
        }

        private func updateWaypointAnnotations(_ map: MKMapView) {
            let existing = Dictionary(
                uniqueKeysWithValues: map.annotations.compactMap { annotation -> (UInt32, WaypointAnnotation)? in
                    guard let annotation = annotation as? WaypointAnnotation else { return nil }
                    return (annotation.waypoint.id, annotation)
                }
            )
            let newIDs = Set(parent.waypoints.map(\.id))
            map.removeAnnotations(existing.compactMap { newIDs.contains($0.key) ? nil : $0.value })
            for waypoint in parent.waypoints {
                if let annotation = existing[waypoint.id] {
                    annotation.waypoint = waypoint
                    annotation.coordinate = .init(latitude: waypoint.latitude, longitude: waypoint.longitude)
                    annotation.title = waypoint.displayName
                    annotation.subtitle = waypoint.detail
                } else {
                    map.addAnnotation(WaypointAnnotation(waypoint: waypoint))
                }
            }
        }

        private func updateEmergencyAnnotations(_ map: MKMapView) {
            let existing = Dictionary(
                uniqueKeysWithValues: map.annotations.compactMap { annotation -> (String, EmergencyAnnotation)? in
                    guard let annotation = annotation as? EmergencyAnnotation else { return nil }
                    return (annotation.feature.id, annotation)
                }
            )
            let visibleFeatures = parent.emergencyFeatures.filter { $0.kind.minimumZoom <= parent.currentZoom }
            let newIDs = Set(visibleFeatures.map(\.id))
            map.removeAnnotations(existing.compactMap { newIDs.contains($0.key) ? nil : $0.value })
            for feature in visibleFeatures where existing[feature.id] == nil {
                map.addAnnotation(EmergencyAnnotation(feature: feature))
            }
        }

        // MARK: Dynamic overlays

        func updateDynamicOverlays(_ map: MKMapView) {
            map.removeOverlays(map.overlays.filter {
                $0 is NodePathPolyline || $0 is NeighborPolyline || $0 is TraceroutePolyline
            })
            map.removeAnnotations(map.annotations.filter { $0 is TracerouteSegmentAnnotation })
            addNodePaths(to: map)
            addNeighborLines(to: map)
            addTraceroutes(to: map)
        }

        private func addNodePaths(to map: MKMapView) {
            let cutoff = parent.positionHistoryHours > 0
                ? Date().addingTimeInterval(TimeInterval(-parent.positionHistoryHours * 3600))
                : .distantPast
            for nodeId in parent.pathNodeIds {
                let positions = LocationLogger.shared.readPositions(for: nodeId)
                    .filter { $0.timestamp >= cutoff }
                guard positions.count >= 2 else { continue }
                let coordinates = positions.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let polyline = NodePathPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.nodeId = nodeId
                polyline.colorHex = parent.nodes.first(where: { $0.id == nodeId })?.colorHex ?? ""
                map.addOverlay(polyline)
            }
        }

        private func addNeighborLines(to map: MKMapView) {
            guard parent.showNeighbors, let ownCoordinate = parent.ownCoordinate else { return }
            let cutoff = parent.showNeighborsPermanently ? Date.distantPast : Date().addingTimeInterval(-24 * 3600)
            var latest: [UInt32: DirectNeighborContact] = [:]
            for contact in parent.directContacts where contact.timestamp >= cutoff {
                if latest[contact.nodeId]?.timestamp ?? .distantPast < contact.timestamp {
                    latest[contact.nodeId] = contact
                }
            }

            for contact in latest.values {
                let node = parent.nodes.first { $0.id == contact.nodeId }
                guard let latitude = contact.latitude ?? node?.latitude,
                      let longitude = contact.longitude ?? node?.longitude else { continue }
                let coordinates = [
                    ownCoordinate.coreLocationCoordinate,
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                ]
                let polyline = NeighborPolyline(coordinates: coordinates, count: 2)
                polyline.nodeId = contact.nodeId
                polyline.snr = contact.snr
                polyline.timestamp = contact.timestamp
                polyline.colorHex = node?.colorHex ?? ""
                polyline.colorMode = parent.neighborColorMode
                let outline = NeighborPolyline(coordinates: coordinates, count: 2)
                outline.isOutline = true
                map.addOverlay(polyline)
                map.insertOverlay(outline, below: polyline)
            }
        }

        private func addTraceroutes(to map: MKMapView) {
            guard parent.showTraceroutes else { return }
            for (index, traceroute) in parent.traceroutes.enumerated() {
                var points: [(coordinate: CLLocationCoordinate2D?, viaMqtt: Bool, snr: Float?)] = []
                let sourceCoordinate = resolvedTracerouteSourceCoordinate(
                    traceroute,
                    ownCoordinate: parent.ownCoordinate,
                    nodes: parent.nodes
                )
                points.append((sourceCoordinate?.coreLocationCoordinate, false, nil))
                points.append(contentsOf: traceroute.hops.map { hop in
                    let coordinate = resolvedTracerouteHopCoordinate(hop, nodes: parent.nodes)
                    return (coordinate?.coreLocationCoordinate, hop.viaMqtt, hop.snr)
                })

                let color = Self.tracerouteColors[index % Self.tracerouteColors.count]
                var lastKnownIndex: Int?
                for pointIndex in points.indices where points[pointIndex].coordinate != nil {
                    guard let previousIndex = lastKnownIndex,
                          let start = points[previousIndex].coordinate,
                          let end = points[pointIndex].coordinate else {
                        lastKnownIndex = pointIndex
                        continue
                    }
                    let unknownSegment = pointIndex - previousIndex > 1
                    let viaMqtt = points[(previousIndex + 1)...pointIndex].contains { $0.viaMqtt }
                    let coordinates = viaMqtt
                        ? Self.mqttZigzag(from: start, to: end)
                        : [start, end]
                    let polyline = TraceroutePolyline(coordinates: coordinates, count: coordinates.count)
                    polyline.color = color
                    polyline.viaMqtt = viaMqtt
                    polyline.unknownSegment = unknownSegment
                    map.addOverlay(polyline)

                    let startPoint = MKMapPoint(start)
                    let endPoint = MKMapPoint(end)
                    let midpoint = MKMapPoint(
                        x: (startPoint.x + endPoint.x) / 2,
                        y: (startPoint.y + endPoint.y) / 2
                    ).coordinate
                    map.addAnnotation(
                        TracerouteSegmentAnnotation(
                            coordinate: midpoint,
                            title: unknownSegment
                                ? String(localized: "Unknown intermediate hop")
                                : String(localized: "Traceroute direction"),
                            subtitle: points[pointIndex].snr.map {
                                String(format: String(localized: "Hop SNR %.1f dB"), $0)
                            },
                            glyph: unknownSegment ? "?" : "➜",
                            color: color
                        )
                    )
                    lastKnownIndex = pointIndex
                }
            }
        }

        // MARK: Context menus

        @objc func handleRightClick(_ recognizer: NSClickGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            if let annotationView = findAnnotationView(at: point, in: map) {
                if let node = annotationView.annotation as? NodeAnnotation {
                    showNodeMenu(node, at: point, in: map)
                    return
                }
                if let waypoint = annotationView.annotation as? WaypointAnnotation {
                    showWaypointMenu(waypoint.waypoint, at: point, in: map)
                    return
                }
            }
            showMapMenu(at: point, in: map)
        }

        private func showNodeMenu(_ annotation: NodeAnnotation, at point: CGPoint, in map: MKMapView) {
            let menu = NSMenu(title: annotation.title ?? String(localized: "Node"))
            let node = parent.appState.node(forId: annotation.nodeId)
            addMenuItem(String(localized: "Send Direct Message"), .sendDM(annotation.nodeId), to: menu)
            addMenuItem(String(localized: "Show Node Info"), .showNodeInfo(annotation.nodeId), to: menu)
            addMenuItem(String(localized: "Show Telemetry"), .telemetry(annotation.nodeId), to: menu)
            if annotation.nodeId != parent.appState.myNodeInfo?.nodeId {
                addMenuItem(String(localized: "Traceroute"), .traceroute(annotation.nodeId), to: menu)
            }
            if node?.isFavorite == true {
                addMenuItem(String(localized: "Remote Administration"), .remoteAdmin(annotation.nodeId), to: menu)
            }

            let requestMenu = NSMenu(title: String(localized: "Request Information"))
            for requestType in NodeInfoRequestType.allCases {
                addMenuItem(
                    requestType.displayName,
                    .requestInfo(annotation.nodeId, requestType),
                    to: requestMenu
                )
            }
            let requests = NSMenuItem(
                title: String(localized: "Request Information"),
                action: nil,
                keyEquivalent: ""
            )
            requests.submenu = requestMenu
            menu.addItem(requests)
            menu.addItem(.separator())

            addMenuItem(
                node?.isFavorite == true
                    ? String(localized: "Remove Favorite")
                    : String(localized: "Add Favorite"),
                .toggleFavorite(annotation.nodeId),
                to: menu
            )
            addMenuItem(
                node?.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin"),
                .togglePin(annotation.nodeId),
                to: menu
            )

            let colorMenu = NSMenu(title: String(localized: "Set Color"))
            for preset in nodeColorPresets {
                let item = addMenuItem(preset.name, .setColor(annotation.nodeId, preset.hex), to: colorMenu)
                item.image = createColorSwatch(hex: preset.hex)
            }
            colorMenu.addItem(.separator())
            addMenuItem(String(localized: "Clear Color"), .setColor(annotation.nodeId, ""), to: colorMenu)
            let colors = NSMenuItem(title: String(localized: "Set Color"), action: nil, keyEquivalent: "")
            colors.submenu = colorMenu
            menu.addItem(colors)

            addMenuItem(String(localized: "Set Note"), .setNote(annotation.nodeId), to: menu)
            menu.addItem(.separator())
            addMenuItem(String(localized: "Set as My Position"), .setAsMyPosition(annotation.nodeId), to: menu)
            if LocationLogger.shared.hasPositionLog(for: annotation.nodeId) {
                let title = parent.pathNodeIds.contains(annotation.nodeId)
                    ? String(localized: "Hide Path")
                    : String(localized: "Show Path")
                addMenuItem(title, .togglePath(annotation.nodeId), to: menu)
            }
            menu.popUp(positioning: nil, at: point, in: map)
        }

        private func showWaypointMenu(_ waypoint: MeshWaypoint, at point: CGPoint, in map: MKMapView) {
            let menu = NSMenu(title: waypoint.displayName)
            addMenuItem(String(localized: "Show Waypoint Info"), .showWaypoint(waypoint.id), to: menu)
            menu.addItem(.separator())
            addMenuItem(String(localized: "Remove from Map"), .deleteWaypoint(waypoint.id, false), to: menu)
            addMenuItem(String(localized: "Delete from Mesh"), .deleteWaypoint(waypoint.id, true), to: menu)
            menu.popUp(positioning: nil, at: point, in: map)
        }

        private func showMapMenu(at point: CGPoint, in map: MKMapView) {
            let coordinate = map.convert(point, toCoordinateFrom: map)
            let menu = NSMenu(title: String(localized: "Map"))
            addMenuItem(String(localized: "Set as My Position"), .setOwnPosition(coordinate), to: menu)
            addMenuItem(String(localized: "Create Waypoint Here"), .createWaypoint(coordinate), to: menu)
            menu.popUp(positioning: nil, at: point, in: map)
        }

        @discardableResult
        private func addMenuItem(_ title: String, _ action: MapContextAction.Kind, to menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MapContextAction(action)
            menu.addItem(item)
            return item
        }

        @objc private func contextMenuAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? MapContextAction else { return }
            switch action.kind {
            case .sendDM(let nodeId): parent.onSendDM(nodeId)
            case .showNodeInfo(let nodeId): parent.onShowNodeInfo(nodeId)
            case .toggleFavorite(let nodeId): parent.onToggleFavorite(nodeId)
            case .togglePin(let nodeId): parent.onTogglePin(nodeId)
            case .traceroute(let nodeId): parent.onTraceroute(nodeId)
            case .telemetry(let nodeId): parent.onTelemetry(nodeId)
            case .remoteAdmin(let nodeId): parent.onRemoteAdmin(nodeId)
            case .requestInfo(let nodeId, let request): parent.onRequestInfo(request, nodeId)
            case .setColor(let nodeId, let hex): applyColor(hex, to: nodeId)
            case .setNote(let nodeId): promptForNote(nodeId: nodeId)
            case .setAsMyPosition(let nodeId): setAsMyPosition(nodeId: nodeId)
            case .togglePath(let nodeId): parent.onTogglePath(nodeId)
            case .setOwnPosition(let coordinate): parent.onSetOwnPosition(coordinate)
            case .createWaypoint(let coordinate): parent.onCreateWaypoint(coordinate)
            case .showWaypoint(let id): parent.onShowWaypoint(id)
            case .deleteWaypoint(let id, let fromMesh): parent.onDeleteWaypoint(id, fromMesh)
            }
        }

        private func findAnnotationView(at point: CGPoint, in map: MKMapView) -> MKAnnotationView? {
            var view: NSView? = map.hitTest(point)
            while let current = view {
                if let annotation = current as? MKAnnotationView { return annotation }
                view = current.superview
            }
            return nil
        }

        private func applyColor(_ hex: String, to nodeId: UInt32) {
            SettingsService.shared.setColorHex(hex, for: nodeId)
            parent.appState.node(forId: nodeId)?.colorHex = hex
        }

        private func promptForNote(nodeId: UInt32) {
            let current = SettingsService.shared.note(for: nodeId)
            let name = parent.appState.node(forId: nodeId)?.name ?? String(localized: "Node")
            let alert = NSAlert()
            alert.messageText = String(localized: "Set Note for \(name)")
            alert.informativeText = String(localized: "Enter a note for this node:")
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = current
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SettingsService.shared.setNote(field.stringValue, for: nodeId)
            parent.appState.node(forId: nodeId)?.note = field.stringValue
        }

        private func setAsMyPosition(nodeId: UInt32) {
            guard let node = parent.appState.node(forId: nodeId),
                  let latitude = node.latitude,
                  let longitude = node.longitude else { return }
            SettingsService.shared.myLatitude = latitude
            SettingsService.shared.myLongitude = longitude
            parent.appState.recalculateAllDistances()
        }

        private func createColorSwatch(hex: String) -> NSImage {
            let image = NSImage(size: .init(width: 12, height: 12))
            image.lockFocus()
            (Color(hex: hex).map(NSColor.init) ?? .gray).setFill()
            NSBezierPath(
                roundedRect: .init(origin: .zero, size: image.size),
                xRadius: 2,
                yRadius: 2
            ).fill()
            image.unlockFocus()
            return image
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let environment = overlay as? EnvironmentSurfaceOverlay {
                return EnvironmentSurfaceRenderer(surfaceOverlay: environment)
            }
            if let path = overlay as? NodePathPolyline {
                let renderer = MKPolylineRenderer(polyline: path)
                renderer.strokeColor = path.colorHex.isEmpty
                    ? .systemBlue
                    : Color(hex: path.colorHex).map(NSColor.init) ?? .systemBlue
                renderer.lineWidth = 2.5
                renderer.alpha = 0.85
                return renderer
            }
            if let neighbor = overlay as? NeighborPolyline {
                let renderer = MKPolylineRenderer(polyline: neighbor)
                renderer.strokeColor = neighbor.isOutline ? .black : Self.neighborColor(for: neighbor)
                renderer.lineWidth = neighbor.isOutline ? 6 : 3
                renderer.alpha = neighbor.isOutline ? 0.55 : 0.95
                renderer.lineCap = .round
                return renderer
            }
            if let traceroute = overlay as? TraceroutePolyline {
                let renderer = MKPolylineRenderer(polyline: traceroute)
                renderer.strokeColor = traceroute.viaMqtt ? .systemYellow : traceroute.color
                renderer.lineWidth = traceroute.viaMqtt ? 3.5 : 2.5
                if traceroute.viaMqtt {
                    renderer.lineDashPattern = [4, 2]
                } else if traceroute.unknownSegment {
                    renderer.lineDashPattern = [7, 5]
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let node = annotation as? NodeAnnotation {
                let identifier = "NodePin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: node, reuseIdentifier: identifier)
                view.annotation = node
                view.canShowCallout = true
                view.markerTintColor = node.colorHex.flatMap(Color.init(hex:)).map(NSColor.init) ?? .systemBlue
                return view
            }
            if let waypoint = annotation as? WaypointAnnotation {
                let identifier = "WaypointPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: waypoint, reuseIdentifier: identifier)
                view.annotation = waypoint
                view.canShowCallout = true
                view.markerTintColor = .systemOrange
                view.glyphText = UnicodeScalar(waypoint.waypoint.icon).map(String.init) ?? "📍"
                return view
            }
            if let emergency = annotation as? EmergencyAnnotation {
                let identifier = "EmergencyPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: emergency, reuseIdentifier: identifier)
                view.annotation = emergency
                view.canShowCallout = true
                view.markerTintColor = Color(hex: emergency.feature.kind.markerColorHex).map(NSColor.init) ?? .systemRed
                view.glyphImage = NSImage(systemSymbolName: emergency.feature.kind.symbolName, accessibilityDescription: emergency.title)
                if emergency.feature.localizedDetailText.isEmpty {
                    view.detailCalloutAccessoryView = nil
                } else {
                    let label = NSTextField(wrappingLabelWithString: emergency.feature.localizedDetailText)
                    label.maximumNumberOfLines = 12
                    label.preferredMaxLayoutWidth = 300
                    view.detailCalloutAccessoryView = label
                }
                return view
            }
            if let box = annotation as? EnvironmentBoxAnnotation {
                let identifier = "EnvironmentBox"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? EnvironmentBoxAnnotationView
                    ?? EnvironmentBoxAnnotationView(annotation: box, reuseIdentifier: identifier)
                view.annotation = box
                view.configure(with: box.box, dark: parent.configuration.source == .dark)
                return view
            }
            if let segment = annotation as? TracerouteSegmentAnnotation {
                let identifier = "TracerouteSegment"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: segment, reuseIdentifier: identifier)
                view.annotation = segment
                view.canShowCallout = true
                view.markerTintColor = segment.color.withAlphaComponent(0.88)
                view.glyphText = segment.glyph
                view.displayPriority = .required
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let node = view.annotation as? NodeAnnotation else { return }
            guard let ownCoordinate = parent.ownCoordinate else {
                node.subtitle = parent.appState.node(forId: node.nodeId)?.nodeId ?? ""
                return
            }
            let origin = CLLocation(latitude: ownCoordinate.latitude, longitude: ownCoordinate.longitude)
            let destination = CLLocation(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
            let distance = origin.distance(from: destination)
            let formatted = distance < 1_000
                ? String(format: "%.0f m", distance)
                : String(format: "%.1f km", distance / 1_000)
            let nodeID = parent.appState.node(forId: node.nodeId)?.nodeId ?? ""
            node.subtitle = "\(nodeID) · \(formatted) \(String(localized: "away"))"
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let span = max(mapView.region.span.longitudeDelta, 0.000_001)
            let zoom = max(1, min(20, Int(round(log2(360 / span)))))
            if parent.currentZoom != zoom { parent.currentZoom = zoom }
            let region = mapView.region
            let bounds = MapBounds(
                north: min(85, region.center.latitude + region.span.latitudeDelta / 2),
                south: max(-85, region.center.latitude - region.span.latitudeDelta / 2),
                east: min(180, region.center.longitude + region.span.longitudeDelta / 2),
                west: max(-180, region.center.longitude - region.span.longitudeDelta / 2)
            )
            if bounds.isValid { parent.onVisibleRegionChanged(bounds, zoom) }
        }

        // MARK: Colors and geometry

        private static let tracerouteColors: [NSColor] = [
            .systemPink, .systemGreen, .systemBlue, .systemOrange,
            .systemPurple, .systemTeal, .systemRed,
        ]

        private static func neighborColor(for line: NeighborPolyline) -> NSColor {
            switch line.colorMode {
            case .nodeColor:
                return Color(hex: line.colorHex).map(NSColor.init) ?? .systemBlue
            case .signalQuality:
                let value = max(-20, min(10, line.snr ?? -20))
                let t = CGFloat((value + 20) / 30)
                return t < 0.5
                    ? interpolate(.systemRed, .systemYellow, t * 2)
                    : interpolate(.systemYellow, .systemGreen, (t - 0.5) * 2)
            case .age:
                let fraction = CGFloat(max(0, min(1, Date().timeIntervalSince(line.timestamp) / (24 * 3600))))
                return interpolate(.systemCyan, .systemPurple, fraction)
            }
        }

        private static func interpolate(_ start: NSColor, _ end: NSColor, _ fraction: CGFloat) -> NSColor {
            let start = start.usingColorSpace(.deviceRGB) ?? start
            let end = end.usingColorSpace(.deviceRGB) ?? end
            return NSColor(
                red: start.redComponent + (end.redComponent - start.redComponent) * fraction,
                green: start.greenComponent + (end.greenComponent - start.greenComponent) * fraction,
                blue: start.blueComponent + (end.blueComponent - start.blueComponent) * fraction,
                alpha: 1
            )
        }

        private static func mqttZigzag(
            from start: CLLocationCoordinate2D,
            to end: CLLocationCoordinate2D,
            peaks: Int = 5
        ) -> [CLLocationCoordinate2D] {
            let startPoint = MKMapPoint(start)
            let endPoint = MKMapPoint(end)
            let dx = endPoint.x - startPoint.x
            let dy = endPoint.y - startPoint.y
            let length = hypot(dx, dy)
            guard length > 1 else { return [start, end] }
            let normalX = -dy / length
            let normalY = dx / length
            let amplitude = length * 0.03
            var result = [start]
            for index in 0..<(peaks * 2) {
                let fraction = Double(index + 1) / Double(peaks * 2 + 1)
                let side = index.isMultiple(of: 2) ? amplitude : -amplitude
                result.append(
                    MKMapPoint(
                        x: startPoint.x + dx * fraction + normalX * side,
                        y: startPoint.y + dy * fraction + normalY * side
                    ).coordinate
                )
            }
            result.append(end)
            return result
        }
    }
}

// MARK: - MapKit model objects

private final class MapContextAction: NSObject {
    enum Kind {
        case sendDM(UInt32)
        case showNodeInfo(UInt32)
        case toggleFavorite(UInt32)
        case togglePin(UInt32)
        case traceroute(UInt32)
        case telemetry(UInt32)
        case remoteAdmin(UInt32)
        case requestInfo(UInt32, NodeInfoRequestType)
        case setColor(UInt32, String)
        case setNote(UInt32)
        case setAsMyPosition(UInt32)
        case togglePath(UInt32)
        case setOwnPosition(CLLocationCoordinate2D)
        case createWaypoint(CLLocationCoordinate2D)
        case showWaypoint(UInt32)
        case deleteWaypoint(UInt32, Bool)
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

private final class NodeAnnotation: NSObject, MKAnnotation {
    let nodeId: UInt32
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    var colorHex: String?

    init(nodeId: UInt32, coordinate: CLLocationCoordinate2D) {
        self.nodeId = nodeId
        self.coordinate = coordinate
    }
}

private final class WaypointAnnotation: NSObject, MKAnnotation {
    var waypoint: MeshWaypoint
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?

    init(waypoint: MeshWaypoint) {
        self.waypoint = waypoint
        coordinate = .init(latitude: waypoint.latitude, longitude: waypoint.longitude)
        title = waypoint.displayName
        subtitle = waypoint.detail
    }
}

private final class EmergencyAnnotation: NSObject, MKAnnotation {
    let feature: EmergencyMapFeature
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?

    init(feature: EmergencyMapFeature) {
        self.feature = feature
        coordinate = .init(latitude: feature.latitude, longitude: feature.longitude)
        title = feature.name
        subtitle = feature.kind.localizedName
    }
}

private final class TracerouteSegmentAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    let glyph: String
    let color: NSColor

    init(
        coordinate: CLLocationCoordinate2D,
        title: String,
        subtitle: String?,
        glyph: String,
        color: NSColor
    ) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.color = color
    }
}

// MARK: - Environment overlay (raster map)

private final class EnvironmentBoxAnnotation: NSObject, MKAnnotation {
    let box: EnvironmentValueBox
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(box: EnvironmentValueBox) {
        self.box = box
        coordinate = .init(latitude: box.latitude, longitude: box.longitude)
    }
}

/// Light-yellow value box drawn just below the node pin (Windows look).
private final class EnvironmentBoxAnnotationView: MKAnnotationView {
    private let label = NSTextField(labelWithString: "")
    private static let padding = CGSize(width: 6, height: 3)

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        collisionMode = .none
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(red: 1, green: 0.973, blue: 0.769, alpha: 0.95).cgColor
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(with box: EnvironmentValueBox, dark: Bool) {
        let text = NSMutableAttributedString(
            string: box.title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black]
        )
        for line in box.lines {
            text.append(NSAttributedString(
                string: "\n\(line)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
            ))
        }
        if !box.time.isEmpty {
            text.append(NSAttributedString(
                string: "\n\(box.time)",
                attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black.withAlphaComponent(0.65)]
            ))
        }
        label.attributedStringValue = text
        let size = label.fittingSize
        label.frame = CGRect(origin: CGPoint(x: Self.padding.width, y: Self.padding.height), size: size)
        frame.size = CGSize(width: size.width + Self.padding.width * 2, height: size.height + Self.padding.height * 2)
        layer?.borderColor = (dark ? NSColor.white : NSColor.black).cgColor
        // Top edge of the box ~10 pt below the node coordinate.
        centerOffset = CGPoint(x: 0, y: frame.height / 2 + 10)
    }
}

/// The interpolated environment surface as one georeferenced image.
private final class EnvironmentSurfaceOverlay: NSObject, MKOverlay {
    let surface: EnvironmentSurface
    let image: CGImage?
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(surface: EnvironmentSurface) {
        self.surface = surface
        image = EnvironmentRaster.cgImage(surface.image)
        let northWest = MKMapPoint(.init(latitude: surface.image.maxLatitude, longitude: surface.image.minLongitude))
        let southEast = MKMapPoint(.init(latitude: surface.image.minLatitude, longitude: surface.image.maxLongitude))
        boundingMapRect = MKMapRect(
            x: northWest.x,
            y: northWest.y,
            width: southEast.x - northWest.x,
            height: southEast.y - northWest.y
        )
        coordinate = .init(
            latitude: (surface.image.minLatitude + surface.image.maxLatitude) / 2,
            longitude: (surface.image.minLongitude + surface.image.maxLongitude) / 2
        )
    }
}

/// Draws the heatmap image (bilinear smoothing) plus contour lines and the coverage border.
private final class EnvironmentSurfaceRenderer: MKOverlayRenderer {
    private let surfaceOverlay: EnvironmentSurfaceOverlay

    init(surfaceOverlay: EnvironmentSurfaceOverlay) {
        self.surfaceOverlay = surfaceOverlay
        super.init(overlay: surfaceOverlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: surfaceOverlay.boundingMapRect)
        if let image = surfaceOverlay.image {
            context.saveGState()
            context.interpolationQuality = .high
            // Renderer space grows southwards; CGImage rows grow northwards → flip.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        strokeSegments(surfaceOverlay.surface.contours, color: NSColor(white: 0.16, alpha: 0.5), width: 0.8,
                       zoomScale: zoomScale, in: context)
        strokeSegments(surfaceOverlay.surface.border, color: NSColor(white: 0.12, alpha: 0.85), width: 1.6,
                       zoomScale: zoomScale, in: context)
    }

    private func strokeSegments(
        _ segments: [EnvironmentSegment],
        color: NSColor,
        width: CGFloat,
        zoomScale: MKZoomScale,
        in context: CGContext
    ) {
        guard !segments.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width / zoomScale)
        context.setLineCap(.round)
        for segment in segments {
            let start = point(for: MKMapPoint(.init(latitude: segment.lat1, longitude: segment.lon1)))
            let end = point(for: MKMapPoint(.init(latitude: segment.lat2, longitude: segment.lon2)))
            context.move(to: start)
            context.addLine(to: end)
        }
        context.strokePath()
        context.restoreGState()
    }
}

private final class NodePathPolyline: MKPolyline {
    var nodeId: UInt32 = 0
    var colorHex = ""
}

private final class NeighborPolyline: MKPolyline {
    var nodeId: UInt32 = 0
    var snr: Float?
    var timestamp = Date()
    var colorHex = ""
    var colorMode = NeighborLineColorMode.signalQuality
    var isOutline = false
}

private final class TraceroutePolyline: MKPolyline {
    var color = NSColor.systemPink
    var viaMqtt = false
    var unknownSegment = false
}
