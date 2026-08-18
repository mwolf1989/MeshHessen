import AppKit
import CoreLocation
import MapKit
import SwiftUI
import WebKit

/// MapLibre GL JS renderer used for the real Mesh Hessen vector styles. HTTP
/// resources are routed through `VectorResourceSchemeHandler`, which supplies
/// the required user agent and persistent offline cache.
struct VectorMeshMapViewRepresentable: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var currentZoom: Int
    let configuration: MapRuntimeConfiguration
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
    let emergencyOverlayEnabled: Bool
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
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.preferences.isElementFullscreenEnabled = false
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.userContentController.add(context.coordinator, name: "meshMap")

        let resourceHandler = VectorResourceSchemeHandler(cache: .shared)
        webConfiguration.setURLSchemeHandler(resourceHandler, forURLScheme: VectorResourceSchemeHandler.scheme)
        context.coordinator.resourceHandler = resourceHandler

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = MapTilePolicy.userAgent
        webView.allowsMagnification = false
        context.coordinator.webView = webView

        guard let htmlURL = VectorMapAssets.mapHTMLURL else {
            context.coordinator.failRenderer(
                String(localized: "The bundled MapLibre renderer could not be found.")
            )
            return webView
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateRenderer()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.snapshotTask?.cancel()
        coordinator.readyTimeoutTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "meshMap")
        webView.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.resourceHandler = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: VectorMeshMapViewRepresentable
        weak var webView: WKWebView?
        var resourceHandler: VectorResourceSchemeHandler?
        var snapshotTask: Task<Void, Never>?
        var readyTimeoutTask: Task<Void, Never>?

        private var navigationReady = false
        private var mapReady = false
        private var loadedStyleURL: String?
        private var lastFocusNodeId: UInt32?
        private var lastSnapshotFingerprint = ""

        init(_ parent: VectorMeshMapViewRepresentable) {
            self.parent = parent
        }

        func updateRenderer() {
            Task {
                await VectorTileCacheService.shared.setOfflineOnly(parent.configuration.offlineOnly)
            }

            guard navigationReady else { return }
            let styleURL = parent.configuration.vectorStyleURL
            if mapReady, loadedStyleURL != styleURL {
                loadedStyleURL = styleURL
                call("return setStyle(styleURL);", arguments: ["styleURL": styleURL])
            }

            if let focusNodeId = parent.focusNodeId,
               focusNodeId != lastFocusNodeId,
               let node = parent.nodes.first(where: { $0.id == focusNodeId }),
               let latitude = node.latitude,
               let longitude = node.longitude {
                lastFocusNodeId = focusNodeId
                call(
                    "return setCenter(longitude, latitude, zoom);",
                    arguments: ["longitude": longitude, "latitude": latitude, "zoom": 15]
                )
            } else if parent.focusNodeId == nil {
                lastFocusNodeId = nil
            }

            scheduleSnapshotPush()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            navigationReady = true
            loadedStyleURL = parent.configuration.vectorStyleURL
            let language = Locale.current.language.languageCode?.identifier == "en" ? "en" : "de"
            call(
                "return initMap(styleURL, longitude, latitude, zoom, attribution, language);",
                arguments: [
                    "styleURL": parent.configuration.vectorStyleURL,
                    "longitude": parent.region.center.longitude,
                    "latitude": parent.region.center.latitude,
                    "zoom": parent.currentZoom,
                    "attribution": "© OpenMapTiles © OpenStreetMap contributors",
                    "language": language,
                ]
            )
            readyTimeoutTask?.cancel()
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, !self.mapReady else { return }
                self.failRenderer(String(localized: "The vector map could not be initialized."))
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            failRenderer(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failRenderer(error.localizedDescription)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "meshMap", let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }
            switch type {
            case "ready":
                mapReady = true
                readyTimeoutTask?.cancel()
                lastSnapshotFingerprint = ""
                pushSnapshot()
            case "viewport":
                updateViewport(from: payload)
            case "nodeclick":
                if let nodeId = Self.uint32(payload["id"]) { parent.onShowNodeInfo(nodeId) }
            case "nodecontext":
                guard let nodeId = Self.uint32(payload["id"]) else { return }
                showNodeMenu(nodeId: nodeId, at: menuPoint(from: payload))
            case "waypointcontext":
                guard let waypointId = Self.uint32(payload["id"]),
                      let waypoint = parent.waypoints.first(where: { $0.id == waypointId }) else { return }
                showWaypointMenu(waypoint, at: menuPoint(from: payload))
            case "mapcontext":
                guard let latitude = payload["lat"] as? Double,
                      let longitude = payload["lon"] as? Double else { return }
                showMapMenu(
                    coordinate: .init(latitude: latitude, longitude: longitude),
                    at: menuPoint(from: payload)
                )
            case "lineclick":
                showSegmentDetails(payload["props"] as? [String: Any])
            case "maperror":
                let detail = payload["message"] as? String ?? String(localized: "Unknown vector-map error")
                AppLogger.shared.log("[VectorMap] \(detail)")
            default:
                break
            }
        }

        func failRenderer(_ message: String) {
            AppLogger.shared.log("[VectorMap] Falling back to raster: \(message)")
            SettingsService.shared.mapRenderMode = .raster
            parent.onError(
                String(localized: "Vector rendering is unavailable. The raster map has been activated. \(message)")
            )
        }

        // MARK: Snapshot bridge

        private func scheduleSnapshotPush() {
            guard mapReady else { return }
            snapshotTask?.cancel()
            snapshotTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.pushSnapshot()
            }
        }

        private func pushSnapshot() {
            guard mapReady else { return }
            let nodes = nodePayload()
            let waypoints = waypointPayload()
            let paths = pathFeatureCollection()
            let neighbors = neighborFeatureCollection()
            let traceroutes = tracerouteFeatureCollection()
            let emergency = emergencyFeatureCollection()
            let ownLabel = effectiveStationName()
            let fingerprintObject: [String: Any] = [
                "nodes": nodes,
                "waypoints": waypoints,
                "paths": paths,
                "neighbors": neighbors,
                "traceroutes": traceroutes,
                "emergency": emergency,
                "overlay": parent.emergencyOverlayEnabled,
                "own": parent.ownCoordinate.map { [$0.longitude, $0.latitude, ownLabel] } ?? [],
            ]
            let fingerprint = (try? JSONSerialization.data(
                withJSONObject: fingerprintObject,
                options: [.sortedKeys]
            ).base64EncodedString()) ?? UUID().uuidString
            guard fingerprint != lastSnapshotFingerprint else { return }
            lastSnapshotFingerprint = fingerprint

            call("return setNodes(nodes);", arguments: ["nodes": nodes])
            call("return setWaypoints(waypoints);", arguments: ["waypoints": waypoints])
            if let own = parent.ownCoordinate {
                call(
                    "return setMyPosition(longitude, latitude, label);",
                    arguments: [
                        "longitude": own.longitude,
                        "latitude": own.latitude,
                        "label": ownLabel,
                    ]
                )
            } else {
                call("return clearMyPosition();")
            }
            call("return setLines('paths', featureCollection);", arguments: ["featureCollection": paths])
            call("return setLines('neighbors', featureCollection);", arguments: ["featureCollection": neighbors])
            call("return setLines('traceroutes', featureCollection);", arguments: ["featureCollection": traceroutes])
            call("return setLines('emergency-fallback', featureCollection);", arguments: ["featureCollection": emergency])
            call(
                "return setOverlay('em-', enabled);",
                arguments: ["enabled": parent.emergencyOverlayEnabled]
            )
        }

        private func effectiveStationName() -> String {
            let settings = SettingsService.shared
            let global = settings.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !global.isEmpty { return global }

            guard let node = parent.appState.myNodeInfo else { return String(localized: "Me") }
            let perNode = settings.stationName(for: node.nodeId)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !perNode.isEmpty { return perNode }

            let shortName = node.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            return shortName.isEmpty ? node.nodeIdHex : shortName
        }

        private func nodePayload() -> [[String: Any]] {
            parent.nodes.compactMap { node in
                guard let latitude = node.latitude, let longitude = node.longitude else { return nil }
                let baseLabel = node.shortName.isEmpty ? node.nodeId : node.shortName
                let label = node.note.isEmpty ? baseLabel : "\(baseLabel) (\(node.note))"
                return [
                    "id": node.id,
                    "lon": longitude,
                    "lat": latitude,
                    "color": normalizedColor(node.colorHex, fallback: "#E53935"),
                    "label": label,
                ]
            }
        }

        private func waypointPayload() -> [[String: Any]] {
            parent.waypoints.map { waypoint in
                let icon = UnicodeScalar(waypoint.icon).map(String.init) ?? "📍"
                return [
                    "id": waypoint.id,
                    "lon": waypoint.longitude,
                    "lat": waypoint.latitude,
                    "label": "\(icon) \(waypoint.displayName)",
                ]
            }
        }

        private func pathFeatureCollection() -> [String: Any] {
            let cutoff = parent.positionHistoryHours > 0
                ? Date().addingTimeInterval(TimeInterval(-parent.positionHistoryHours * 3_600))
                : .distantPast
            var features: [[String: Any]] = []
            for nodeId in parent.pathNodeIds {
                let coordinates = LocationLogger.shared.readPositions(for: nodeId)
                    .filter { $0.timestamp >= cutoff }
                    .map { [$0.longitude, $0.latitude] }
                guard coordinates.count >= 2 else { continue }
                let color = normalizedColor(
                    parent.nodes.first(where: { $0.id == nodeId })?.colorHex ?? "",
                    fallback: "#1976D2"
                )
                features.append(lineFeature(coordinates: coordinates, properties: ["color": color, "width": 2.5]))
            }
            return featureCollection(features)
        }

        private func neighborFeatureCollection() -> [String: Any] {
            guard parent.showNeighbors, let own = parent.ownCoordinate else { return featureCollection([]) }
            let cutoff = parent.showNeighborsPermanently ? Date.distantPast : Date().addingTimeInterval(-86_400)
            var latest: [UInt32: DirectNeighborContact] = [:]
            for contact in parent.directContacts where contact.timestamp >= cutoff {
                if latest[contact.nodeId]?.timestamp ?? .distantPast < contact.timestamp {
                    latest[contact.nodeId] = contact
                }
            }

            var features: [[String: Any]] = []
            for contact in latest.values {
                let node = parent.nodes.first(where: { $0.id == contact.nodeId })
                guard let latitude = contact.latitude ?? node?.latitude,
                      let longitude = contact.longitude ?? node?.longitude else { continue }
                let coordinates = [[own.longitude, own.latitude], [longitude, latitude]]
                features.append(
                    lineFeature(
                        coordinates: coordinates,
                        properties: ["color": "#111111", "width": 6, "outline": 1]
                    )
                )
                features.append(
                    lineFeature(
                        coordinates: coordinates,
                        properties: [
                            "color": neighborColor(contact: contact, node: node),
                            "width": 3,
                            "nodeId": contact.nodeId,
                        ]
                    )
                )
            }
            return featureCollection(features)
        }

        private func tracerouteFeatureCollection() -> [String: Any] {
            guard parent.showTraceroutes else { return featureCollection([]) }
            var features: [[String: Any]] = []
            for (routeIndex, route) in parent.traceroutes.enumerated() {
                let color = Self.tracerouteColors[routeIndex % Self.tracerouteColors.count]
                let ownId = route.sourceNodeId ?? parent.appState.myNodeInfo?.nodeId ?? 0
                let sourceCoordinate = resolvedTracerouteSourceCoordinate(
                    route,
                    ownCoordinate: parent.ownCoordinate,
                    nodes: parent.nodes
                )
                var points: [TracePoint] = [
                    .init(
                        nodeId: ownId,
                        coordinate: sourceCoordinate.map { [$0.longitude, $0.latitude] },
                        viaMqtt: false,
                        snr: nil
                    ),
                ]
                points.append(contentsOf: route.hops.map { hop in
                    let coordinate = resolvedTracerouteHopCoordinate(hop, nodes: parent.nodes)
                    return TracePoint(
                        nodeId: hop.nodeId,
                        coordinate: coordinate.map { [$0.longitude, $0.latitude] },
                        viaMqtt: hop.viaMqtt,
                        snr: hop.snr
                    )
                })

                var lastKnownIndex: Int?
                for pointIndex in points.indices where points[pointIndex].coordinate != nil {
                    guard let previousIndex = lastKnownIndex,
                          let start = points[previousIndex].coordinate,
                          let end = points[pointIndex].coordinate else {
                        lastKnownIndex = pointIndex
                        continue
                    }
                    let unknown = pointIndex - previousIndex > 1
                    let mqtt = points[(previousIndex + 1)...pointIndex].contains(where: \.viaMqtt)
                    let coordinates = mqtt ? mqttZigzag(from: start, to: end) : [start, end]
                    var lineProperties: [String: Any] = ["color": mqtt ? "#FBC02D" : color, "width": 2.8]
                    if mqtt || unknown { lineProperties["dash"] = 1 }
                    features.append(lineFeature(coordinates: coordinates, properties: lineProperties))

                    let midpoint = [(start[0] + end[0]) / 2, (start[1] + end[1]) / 2]
                    var properties: [String: Any] = [
                        "color": color,
                        "radius": 5,
                        "click": 1,
                        "fromId": points[previousIndex].nodeId,
                        "toId": points[pointIndex].nodeId,
                        "mqtt": mqtt ? 1 : 0,
                    ]
                    if unknown {
                        properties["label"] = "?"
                    } else {
                        properties["bearing"] = bearing(from: start, to: end)
                        properties["iconSize"] = 0.45
                    }
                    if let snr = points[pointIndex].snr { properties["snr"] = snr }
                    features.append(pointFeature(coordinate: midpoint, properties: properties))
                    lastKnownIndex = pointIndex
                }
            }
            return featureCollection(features)
        }

        private func emergencyFeatureCollection() -> [String: Any] {
            // Official Mesh Hessen styles already contain the MVT emergency
            // layers. Custom styles receive the cached Overpass points instead.
            guard parent.emergencyOverlayEnabled, parent.configuration.mode != .meshHessen else {
                return featureCollection([])
            }
            let features = parent.emergencyFeatures
                .filter { $0.kind.minimumZoom <= parent.currentZoom }
                .map { feature in
                    pointFeature(
                        coordinate: [feature.longitude, feature.latitude],
                        properties: [
                            "color": feature.kind.markerColorHex,
                            "radius": 6,
                            "label": feature.name,
                        ]
                    )
                }
            return featureCollection(features)
        }

        private func call(_ body: String, arguments: [String: Any] = [:]) {
            guard let webView else { return }
            Task {
                do {
                    _ = try await webView.callAsyncJavaScript(
                        body,
                        arguments: arguments,
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    AppLogger.shared.log("[VectorMap] JavaScript bridge error: \(error.localizedDescription)")
                }
            }
        }

        // MARK: Viewport and menus

        private func updateViewport(from payload: [String: Any]) {
            guard let latitude = payload["lat"] as? Double,
                  let longitude = payload["lon"] as? Double,
                  let west = payload["west"] as? Double,
                  let south = payload["south"] as? Double,
                  let east = payload["east"] as? Double,
                  let north = payload["north"] as? Double,
                  let zoom = payload["zoom"] as? Double else { return }
            let roundedZoom = max(1, min(20, Int(zoom.rounded())))
            parent.region = .init(
                center: .init(latitude: latitude, longitude: longitude),
                span: .init(latitudeDelta: north - south, longitudeDelta: east - west)
            )
            if parent.currentZoom != roundedZoom { parent.currentZoom = roundedZoom }
            let bounds = MapBounds(north: north, south: south, east: east, west: west)
            if bounds.isValid { parent.onVisibleRegionChanged(bounds, roundedZoom) }
        }

        private func menuPoint(from payload: [String: Any]) -> CGPoint {
            guard let view = webView else { return .zero }
            let x = payload["x"] as? Double ?? Double(view.bounds.midX)
            let y = payload["y"] as? Double ?? Double(view.bounds.midY)
            return .init(x: x, y: Double(view.bounds.height) - y)
        }

        private func showNodeMenu(nodeId: UInt32, at point: CGPoint) {
            guard let view = webView else { return }
            let node = parent.appState.node(forId: nodeId)
            let menu = NSMenu(title: node?.name ?? String(localized: "Node"))
            addMenuItem(String(localized: "Send Direct Message"), .sendDM(nodeId), to: menu)
            addMenuItem(String(localized: "Show Node Info"), .showNodeInfo(nodeId), to: menu)
            addMenuItem(String(localized: "Show Telemetry"), .telemetry(nodeId), to: menu)
            if nodeId != parent.appState.myNodeInfo?.nodeId {
                addMenuItem(String(localized: "Traceroute"), .traceroute(nodeId), to: menu)
            }
            if node?.isFavorite == true {
                addMenuItem(String(localized: "Remote Administration"), .remoteAdmin(nodeId), to: menu)
            }

            let requestMenu = NSMenu(title: String(localized: "Request Information"))
            for request in NodeInfoRequestType.allCases {
                addMenuItem(request.displayName, .requestInfo(nodeId, request), to: requestMenu)
            }
            let requestItem = NSMenuItem(title: String(localized: "Request Information"), action: nil, keyEquivalent: "")
            requestItem.submenu = requestMenu
            menu.addItem(requestItem)
            menu.addItem(.separator())
            addMenuItem(
                node?.isFavorite == true ? String(localized: "Remove Favorite") : String(localized: "Add Favorite"),
                .toggleFavorite(nodeId),
                to: menu
            )
            addMenuItem(
                node?.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin"),
                .togglePin(nodeId),
                to: menu
            )

            let colorMenu = NSMenu(title: String(localized: "Set Color"))
            for preset in nodeColorPresets {
                let item = addMenuItem(preset.name, .setColor(nodeId, preset.hex), to: colorMenu)
                item.image = colorSwatch(hex: preset.hex)
            }
            colorMenu.addItem(.separator())
            addMenuItem(String(localized: "Clear Color"), .setColor(nodeId, ""), to: colorMenu)
            let colorItem = NSMenuItem(title: String(localized: "Set Color"), action: nil, keyEquivalent: "")
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
            addMenuItem(String(localized: "Set Note"), .setNote(nodeId), to: menu)
            menu.addItem(.separator())
            addMenuItem(String(localized: "Set as My Position"), .setAsMyPosition(nodeId), to: menu)
            if LocationLogger.shared.hasPositionLog(for: nodeId) {
                addMenuItem(
                    parent.pathNodeIds.contains(nodeId) ? String(localized: "Hide Path") : String(localized: "Show Path"),
                    .togglePath(nodeId),
                    to: menu
                )
            }
            menu.popUp(positioning: nil, at: point, in: view)
        }

        private func showWaypointMenu(_ waypoint: MeshWaypoint, at point: CGPoint) {
            guard let view = webView else { return }
            let menu = NSMenu(title: waypoint.displayName)
            addMenuItem(String(localized: "Show Waypoint Info"), .showWaypoint(waypoint.id), to: menu)
            menu.addItem(.separator())
            addMenuItem(String(localized: "Remove from Map"), .deleteWaypoint(waypoint.id, false), to: menu)
            addMenuItem(String(localized: "Delete from Mesh"), .deleteWaypoint(waypoint.id, true), to: menu)
            menu.popUp(positioning: nil, at: point, in: view)
        }

        private func showMapMenu(coordinate: CLLocationCoordinate2D, at point: CGPoint) {
            guard let view = webView else { return }
            let menu = NSMenu(title: String(localized: "Map"))
            addMenuItem(String(localized: "Set as My Position"), .setOwnPosition(coordinate), to: menu)
            addMenuItem(String(localized: "Create Waypoint Here"), .createWaypoint(coordinate), to: menu)
            menu.popUp(positioning: nil, at: point, in: view)
        }

        @discardableResult
        private func addMenuItem(
            _ title: String,
            _ action: VectorMapContextAction.Kind,
            to menu: NSMenu
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = VectorMapContextAction(action)
            menu.addItem(item)
            return item
        }

        @objc private func contextMenuAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? VectorMapContextAction else { return }
            switch action.kind {
            case .sendDM(let id): parent.onSendDM(id)
            case .showNodeInfo(let id): parent.onShowNodeInfo(id)
            case .toggleFavorite(let id): parent.onToggleFavorite(id)
            case .togglePin(let id): parent.onTogglePin(id)
            case .traceroute(let id): parent.onTraceroute(id)
            case .telemetry(let id): parent.onTelemetry(id)
            case .remoteAdmin(let id): parent.onRemoteAdmin(id)
            case .requestInfo(let id, let request): parent.onRequestInfo(request, id)
            case .setColor(let id, let hex):
                SettingsService.shared.setColorHex(hex, for: id)
                parent.appState.node(forId: id)?.colorHex = hex
            case .setNote(let id): promptForNote(nodeId: id)
            case .setAsMyPosition(let id):
                guard let node = parent.appState.node(forId: id),
                      let latitude = node.latitude, let longitude = node.longitude else { return }
                parent.onSetOwnPosition(.init(latitude: latitude, longitude: longitude))
            case .togglePath(let id): parent.onTogglePath(id)
            case .setOwnPosition(let coordinate): parent.onSetOwnPosition(coordinate)
            case .createWaypoint(let coordinate): parent.onCreateWaypoint(coordinate)
            case .showWaypoint(let id): parent.onShowWaypoint(id)
            case .deleteWaypoint(let id, let fromMesh): parent.onDeleteWaypoint(id, fromMesh)
            }
        }

        private func promptForNote(nodeId: UInt32) {
            let field = NSTextField(frame: .init(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = SettingsService.shared.note(for: nodeId)
            let alert = NSAlert()
            alert.messageText = String(localized: "Set Note")
            alert.informativeText = String(localized: "Enter a note for this node:")
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SettingsService.shared.setNote(field.stringValue, for: nodeId)
            parent.appState.node(forId: nodeId)?.note = field.stringValue
        }

        private func showSegmentDetails(_ properties: [String: Any]?) {
            guard let properties else { return }
            let from = Self.uint32(properties["fromId"]).map(String.init) ?? "?"
            let to = Self.uint32(properties["toId"]).map(String.init) ?? "?"
            var details = "\(from) → \(to)"
            if let snr = properties["snr"] as? Double {
                details += String(format: "\nSNR %.1f dB", snr)
            }
            if (properties["mqtt"] as? Int) == 1 || (properties["mqtt"] as? Double) == 1 {
                details += "\nMQTT"
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Traceroute Segment")
            alert.informativeText = details
            alert.runModal()
        }

        // MARK: Geometry helpers

        private func featureCollection(_ features: [[String: Any]]) -> [String: Any] {
            ["type": "FeatureCollection", "features": features]
        }

        private func lineFeature(coordinates: [[Double]], properties: [String: Any]) -> [String: Any] {
            [
                "type": "Feature",
                "geometry": ["type": "LineString", "coordinates": coordinates],
                "properties": properties,
            ]
        }

        private func pointFeature(coordinate: [Double], properties: [String: Any]) -> [String: Any] {
            [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": coordinate],
                "properties": properties,
            ]
        }

        private func normalizedColor(_ value: String, fallback: String) -> String {
            guard !value.isEmpty else { return fallback }
            if value.count == 9 { return "#" + value.dropFirst(3) }
            return value
        }

        private func neighborColor(contact: DirectNeighborContact, node: NodeInfo?) -> String {
            switch parent.neighborColorMode {
            case .nodeColor:
                return normalizedColor(node?.colorHex ?? "", fallback: "#1976D2")
            case .signalQuality:
                let value = max(-20, min(10, Double(contact.snr ?? -20)))
                return gradientColor(fraction: (value + 20) / 30, start: (220, 38, 38), middle: (251, 192, 45), end: (46, 125, 50))
            case .age:
                let age = max(0, min(1, Date().timeIntervalSince(contact.timestamp) / 86_400))
                return interpolateColor(from: (0, 188, 212), to: (123, 31, 162), fraction: age)
            }
        }

        private func gradientColor(
            fraction: Double,
            start: (Int, Int, Int),
            middle: (Int, Int, Int),
            end: (Int, Int, Int)
        ) -> String {
            fraction < 0.5
                ? interpolateColor(from: start, to: middle, fraction: fraction * 2)
                : interpolateColor(from: middle, to: end, fraction: (fraction - 0.5) * 2)
        }

        private func interpolateColor(
            from: (Int, Int, Int),
            to: (Int, Int, Int),
            fraction: Double
        ) -> String {
            let value = max(0, min(1, fraction))
            let red = Int(Double(from.0) + Double(to.0 - from.0) * value)
            let green = Int(Double(from.1) + Double(to.1 - from.1) * value)
            let blue = Int(Double(from.2) + Double(to.2 - from.2) * value)
            return String(format: "#%02X%02X%02X", red, green, blue)
        }

        private func mqttZigzag(from start: [Double], to end: [Double], peaks: Int = 5) -> [[Double]] {
            let dx = end[0] - start[0]
            let dy = end[1] - start[1]
            let length = hypot(dx, dy)
            guard length > 0 else { return [start, end] }
            let normalX = -dy / length
            let normalY = dx / length
            let amplitude = length * 0.03
            var result = [start]
            for index in 0..<(peaks * 2) {
                let fraction = Double(index + 1) / Double(peaks * 2 + 1)
                let side = index.isMultiple(of: 2) ? amplitude : -amplitude
                result.append([
                    start[0] + dx * fraction + normalX * side,
                    start[1] + dy * fraction + normalY * side,
                ])
            }
            result.append(end)
            return result
        }

        private func bearing(from start: [Double], to end: [Double]) -> Double {
            let latitude1 = start[1] * .pi / 180
            let latitude2 = end[1] * .pi / 180
            let deltaLongitude = (end[0] - start[0]) * .pi / 180
            let y = sin(deltaLongitude) * cos(latitude2)
            let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
            return atan2(y, x) * 180 / .pi
        }

        private func colorSwatch(hex: String) -> NSImage {
            let image = NSImage(size: .init(width: 12, height: 12))
            image.lockFocus()
            (Color(hex: hex).map(NSColor.init) ?? .gray).setFill()
            NSBezierPath(roundedRect: .init(origin: .zero, size: image.size), xRadius: 2, yRadius: 2).fill()
            image.unlockFocus()
            return image
        }

        private static func uint32(_ value: Any?) -> UInt32? {
            if let number = value as? NSNumber { return UInt32(truncating: number) }
            if let text = value as? String { return UInt32(text) }
            return nil
        }

        private struct TracePoint {
            let nodeId: UInt32
            let coordinate: [Double]?
            let viaMqtt: Bool
            let snr: Float?
        }

        private static let tracerouteColors = [
            "#D81B60", "#43A047", "#1E88E5", "#FB8C00", "#8E24AA", "#00ACC1", "#E53935",
        ]
    }
}

private enum VectorMapAssets {
    static var mapHTMLURL: URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(
            forResource: "map",
            withExtension: "html",
            subdirectory: "Resources/VectorMap"
        ) {
            return url
        }
        #endif

        let candidates: [(String?)] = ["Resources/VectorMap", "VectorMap", nil]
        for subdirectory in candidates {
            if let url = Bundle.main.url(forResource: "map", withExtension: "html", subdirectory: subdirectory) {
                return url
            }
        }
        return Bundle.main.urls(forResourcesWithExtension: "html", subdirectory: nil)?
            .first(where: { $0.lastPathComponent == "map.html" })
    }
}

private final class VectorMapContextAction: NSObject {
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

    init(_ kind: Kind) {
        self.kind = kind
    }
}
