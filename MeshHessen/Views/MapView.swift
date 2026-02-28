import SwiftUI
import MapKit

/// Map tab — native Apple Maps with node annotations.
struct MapView: View {
    @Environment(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var mapStyle: MapStyle
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50.9, longitude: 9.5),
        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
    )
    @State private var showNodeInfo: NodeInfo?
    @State private var currentZoom: Int = 10

    init() {
        _mapStyle = State(initialValue: MapStyle.from(settingsValue: SettingsService.shared.mapSource))
    }

    enum MapStyle: String, CaseIterable, Identifiable {
        case standard = "standard"
        case satellite = "satellite"
        case hybrid = "hybrid"
        var id: String { rawValue }

        static func from(settingsValue: String) -> Self {
            switch settingsValue.lowercased() {
            case "satellite": return .satellite
            case "hybrid":    return .hybrid
            default:          return .standard
            }
        }

        var settingsValue: String { rawValue }

        var label: String {
            switch self {
            case .standard:  return String(localized: "Standard")
            case .satellite: return String(localized: "Satellite")
            case .hybrid:    return String(localized: "Hybrid")
            }
        }

        var mapType: MKMapType {
            switch self {
            case .standard:  return .standard
            case .satellite: return .satellite
            case .hybrid:    return .hybrid
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MeshMapViewRepresentable(
                region: $region,
                currentZoom: $currentZoom,
                mapStyle: mapStyle,
                nodes: appState.filteredNodes,
                focusNodeId: appState.mapFocusNodeId,
                appState: appState,
                onSendDM: { nodeId in
                    appState.ensureDMConversation(for: nodeId)
                    appState.dmTargetNodeId = nodeId
                    openWindow(id: "dm")
                },
                onShowNodeInfo: { nodeId in
                    if let node = appState.node(forId: nodeId) {
                        showNodeInfo = node
                    }
                }
            )

            // Style picker + zoom indicator
            HStack(spacing: 8) {
                Text("Z\(currentZoom)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))

                Picker("Map style", selection: $mapStyle) {
                    ForEach(MapStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(10)
        }
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .onChange(of: mapStyle) { _, newStyle in
            SettingsService.shared.mapSource = newStyle.settingsValue
        }
        .onAppear {
            let fromSettings = MapStyle.from(settingsValue: SettingsService.shared.mapSource)
            if mapStyle != fromSettings {
                mapStyle = fromSettings
            }
        }
        .onChange(of: appState.mapFocusNodeId) { _, newValue in
            if let nodeId = newValue,
               let node = appState.nodes[nodeId],
               let lat = node.latitude, let lon = node.longitude {
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            }
            if newValue != nil {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    appState.mapFocusNodeId = nil
                }
            }
        }
    }
}

/// NSViewRepresentable wrapping MKMapView with native Apple Maps + node annotations.
struct MeshMapViewRepresentable: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var currentZoom: Int
    let mapStyle: MapView.MapStyle
    let nodes: [NodeInfo]
    var focusNodeId: UInt32?
    let appState: AppState
    var onSendDM: ((UInt32) -> Void)?
    var onShowNodeInfo: ((UInt32) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(region, animated: false)
        map.mapType = mapStyle.mapType
        map.showsCompass = true
        map.showsScale = true

        // Add right-click gesture recognizer for context menu
        let rightClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 0x2 // right mouse button
        map.addGestureRecognizer(rightClick)

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateNodes(map, nodes: nodes)
        // Switch map type if style changed
        if context.coordinator.currentStyle != mapStyle {
            context.coordinator.currentStyle = mapStyle
            map.mapType = mapStyle.mapType
        }
        // Center on focus node if requested
        if let focusId = focusNodeId,
           let node = nodes.first(where: { $0.id == focusId }),
           let lat = node.latitude, let lon = node.longitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            map.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
        }
    }

    @MainActor
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MeshMapViewRepresentable
        var currentStyle: MapView.MapStyle = .standard

        init(_ parent: MeshMapViewRepresentable) {
            self.parent = parent
            self.currentStyle = parent.mapStyle
        }

        func updateNodes(_ map: MKMapView, nodes: [NodeInfo]) {
            // Build lookup of existing annotations for O(1) access
            var existingAnnotations: [UInt32: NodeAnnotation] = [:]
            for ann in map.annotations.compactMap({ $0 as? NodeAnnotation }) {
                existingAnnotations[ann.nodeId] = ann
            }

            let newIds = Set(nodes.compactMap { $0.latitude != nil ? $0.id : nil })

            // Remove stale
            for (nodeId, ann) in existingAnnotations {
                if !newIds.contains(nodeId) { map.removeAnnotation(ann) }
            }
            // Add/update
            for node in nodes {
                guard let lat = node.latitude, let lon = node.longitude else { continue }
                if let existing = existingAnnotations[node.id] {
                    existing.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    existing.title = node.name
                    existing.colorHex = node.colorHex
                } else {
                    let ann = NodeAnnotation(nodeId: node.id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    ann.title = node.name
                    ann.subtitle = node.nodeId
                    ann.colorHex = node.colorHex
                    map.addAnnotation(ann)
                }
            }
        }

        // MARK: - Right-click context menu

        @objc func handleRightClick(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)

            guard let annotationView = findAnnotationView(at: point, in: mapView),
                  let nodeAnn = annotationView.annotation as? NodeAnnotation else { return }

            let nodeId = nodeAnn.nodeId
            let nodeName = nodeAnn.title ?? String(localized: "Node")

            let menu = NSMenu(title: nodeName)

            let dmItem = NSMenuItem(title: String(localized: "Send Direct Message"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            dmItem.target = self
            dmItem.representedObject = ContextMenuAction.sendDM(nodeId: nodeId)
            menu.addItem(dmItem)

            let infoItem = NSMenuItem(title: String(localized: "Show Node Info"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            infoItem.target = self
            infoItem.representedObject = ContextMenuAction.showNodeInfo(nodeId: nodeId)
            menu.addItem(infoItem)

            menu.addItem(.separator())

            let colorMenu = NSMenu(title: String(localized: "Set Color"))
            for preset in nodeColorPresets {
                let colorItem = NSMenuItem(title: preset.name, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
                colorItem.target = self
                colorItem.representedObject = ContextMenuAction.setColor(nodeId: nodeId, hex: preset.hex)
                colorItem.image = createColorSwatch(hex: preset.hex)
                colorMenu.addItem(colorItem)
            }
            colorMenu.addItem(.separator())
            let clearColorItem = NSMenuItem(title: String(localized: "Clear Color"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            clearColorItem.target = self
            clearColorItem.representedObject = ContextMenuAction.setColor(nodeId: nodeId, hex: "")
            colorMenu.addItem(clearColorItem)

            let colorMenuItem = NSMenuItem(title: String(localized: "Set Color"), action: nil, keyEquivalent: "")
            colorMenuItem.submenu = colorMenu
            menu.addItem(colorMenuItem)

            let noteItem = NSMenuItem(title: String(localized: "Set Note"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            noteItem.target = self
            noteItem.representedObject = ContextMenuAction.setNote(nodeId: nodeId)
            menu.addItem(noteItem)

            menu.addItem(.separator())

            let posItem = NSMenuItem(title: String(localized: "Set as My Position"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            posItem.target = self
            posItem.representedObject = ContextMenuAction.setAsMyPosition(nodeId: nodeId)
            menu.addItem(posItem)

            menu.popUp(positioning: nil, at: point, in: mapView)
        }

        private func findAnnotationView(at point: CGPoint, in mapView: MKMapView) -> MKAnnotationView? {
            guard let hitView = mapView.hitTest(point) else { return nil }
            var current: NSView? = hitView
            while let view = current {
                if let annotationView = view as? MKAnnotationView {
                    return annotationView
                }
                current = view.superview
            }
            return nil
        }

        private func createColorSwatch(hex: String) -> NSImage {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size)
            image.lockFocus()
            if let color = Color(hex: hex) {
                NSColor(color).setFill()
            } else {
                NSColor.gray.setFill()
            }
            let rect = NSRect(origin: .zero, size: size)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            image.unlockFocus()
            return image
        }

        @objc func contextMenuAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction else { return }

            switch action.kind {
            case .sendDM(let nodeId):
                parent.onSendDM?(nodeId)

            case .showNodeInfo(let nodeId):
                parent.onShowNodeInfo?(nodeId)

            case .setColor(let nodeId, let hex):
                applyColor(hex, to: nodeId)

            case .setNote(let nodeId):
                promptForNote(nodeId: nodeId)

            case .setAsMyPosition(let nodeId):
                setAsMyPosition(nodeId: nodeId)
            }
        }

        private func applyColor(_ hex: String, to nodeId: UInt32) {
            SettingsService.shared.setColorHex(hex, for: nodeId)
            if let node = parent.appState.node(forId: nodeId) {
                node.colorHex = hex
            }
        }

        private func promptForNote(nodeId: UInt32) {
            let currentNote = SettingsService.shared.note(for: nodeId)
            let nodeName = parent.appState.node(forId: nodeId)?.name ?? String(localized: "Node")

            let alert = NSAlert()
            alert.messageText = String(localized: "Set Note for \(nodeName)")
            alert.informativeText = String(localized: "Enter a note for this node:")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            textField.stringValue = currentNote
            textField.placeholderString = String(localized: "Optional note…")
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let note = textField.stringValue
                SettingsService.shared.setNote(note, for: nodeId)
                if let node = parent.appState.node(forId: nodeId) {
                    node.note = note
                }
            }
        }

        private func setAsMyPosition(nodeId: UInt32) {
            guard let node = parent.appState.node(forId: nodeId),
                  let lat = node.latitude,
                  let lon = node.longitude else { return }

            SettingsService.shared.myLatitude = lat
            SettingsService.shared.myLongitude = lon

            parent.appState.recalculateAllDistances()
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let nodeAnn = annotation as? NodeAnnotation else { return nil }
            let id = "NodePin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: nodeAnn, reuseIdentifier: id)
            view.annotation = nodeAnn
            view.canShowCallout = true
            view.glyphText = nil
            if let hex = nodeAnn.colorHex, !hex.isEmpty, let color = Color(hex: hex) {
                view.markerTintColor = NSColor(color)
            } else {
                view.markerTintColor = NSColor.systemBlue
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let nodeAnn = view.annotation as? NodeAnnotation else { return }

            guard let ownCoordinate = parent.appState.effectiveOwnCoordinate() else {
                let nodeIdStr = parent.appState.node(forId: nodeAnn.nodeId)?.nodeId ?? ""
                nodeAnn.subtitle = nodeIdStr
                return
            }

            let myLoc = CLLocation(latitude: ownCoordinate.latitude, longitude: ownCoordinate.longitude)
            let nodeLoc = CLLocation(latitude: nodeAnn.coordinate.latitude,
                                     longitude: nodeAnn.coordinate.longitude)
            let distanceMeters = myLoc.distance(from: nodeLoc)

            let distanceStr: String
            if distanceMeters < 1000 {
                distanceStr = String(format: "%.0f m", distanceMeters)
            } else {
                distanceStr = String(format: "%.1f km", distanceMeters / 1000)
            }

            let nodeIdStr = parent.appState.node(forId: nodeAnn.nodeId)?.nodeId ?? ""
            nodeAnn.subtitle = "\(nodeIdStr)  ·  \(distanceStr) \(String(localized: "away"))"
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let span = mapView.region.span.longitudeDelta
            let zoom = Int(round(log2(360 / span)))
            parent.currentZoom = max(1, min(20, zoom))
        }
    }
}

// MARK: - Context Menu Action

private final class ContextMenuAction: NSObject {
    let kind: Kind

    enum Kind {
        case sendDM(nodeId: UInt32)
        case showNodeInfo(nodeId: UInt32)
        case setColor(nodeId: UInt32, hex: String)
        case setNote(nodeId: UInt32)
        case setAsMyPosition(nodeId: UInt32)
    }

    private init(_ kind: Kind) { self.kind = kind }

    static func sendDM(nodeId: UInt32) -> ContextMenuAction { .init(.sendDM(nodeId: nodeId)) }
    static func showNodeInfo(nodeId: UInt32) -> ContextMenuAction { .init(.showNodeInfo(nodeId: nodeId)) }
    static func setColor(nodeId: UInt32, hex: String) -> ContextMenuAction { .init(.setColor(nodeId: nodeId, hex: hex)) }
    static func setNote(nodeId: UInt32) -> ContextMenuAction { .init(.setNote(nodeId: nodeId)) }
    static func setAsMyPosition(nodeId: UInt32) -> ContextMenuAction { .init(.setAsMyPosition(nodeId: nodeId)) }
}

// MARK: - NodeAnnotation

final class NodeAnnotation: NSObject, MKAnnotation {
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
