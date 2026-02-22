import SwiftUI
import MapKit

// MARK: - CachedTileOverlay

/// MKTileOverlay subclass that serves tiles from a local cache first,
/// falling back to the remote URL template when a cached tile is not found.
///
/// Cache path convention (matches TileDownloaderSheet):
///   ~/Library/Application Support/MeshHessen/tiles/{layer}/{z}_{x}_{y}.png
final class CachedTileOverlay: MKTileOverlay {
    private let layerName: String
    private let cacheBaseURL: URL

    /// - Parameters:
    ///   - urlTemplate: Remote tile URL template (e.g. "https://…/{z}/{x}/{y}.png")
    ///   - layer: Directory name matching TileDownloaderSheet ("osm", "opentopo", "dark")
    init(urlTemplate: String?, layer: String) {
        self.layerName = layer
        self.cacheBaseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshHessen/tiles/\(layer)")
        super.init(urlTemplate: urlTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        // Check local cache first
        let fileName = "\(path.z)_\(path.x)_\(path.y).png"
        let fileURL = cacheBaseURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            result(data, nil)
            return
        }

        // Fall back to remote tile server
        super.loadTile(at: path, result: result)
    }
}

/// Map tab — MKMapView with tile overlay + node annotations.
struct MapView: View {
    @Environment(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var mapStyle: MapStyle = .osm
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50.9, longitude: 9.5),
        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
    )
    @State private var showNodeInfo: NodeInfo?

    enum MapStyle: String, CaseIterable, Identifiable {
        case osm = "osm"
        case topo = "opentopo"
        case dark = "dark"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .osm: return String(localized: "Street")
            case .topo: return String(localized: "Topo")
            case .dark: return String(localized: "Dark")
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MeshMapViewRepresentable(
                region: $region,
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

            // Style picker
            Picker("Map style", selection: $mapStyle) {
                ForEach(MapStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .padding(10)
        }
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .onChange(of: appState.mapFocusNodeId) { _, newValue in
            // Clear focus after MapView processes it
            if let nodeId = newValue,
               let node = appState.nodes[nodeId],
               let lat = node.latitude, let lon = node.longitude {
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
            }
            // Reset focus so it can be triggered again
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    appState.mapFocusNodeId = nil
                }
            }
        }
    }
}

/// NSViewRepresentable wrapping MKMapView with offline tile overlay.
struct MeshMapViewRepresentable: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
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
        map.showsCompass = true
        map.showsScale = true
        context.coordinator.applyTileOverlay(to: map, style: mapStyle)

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
        // Swap tile overlay if style changed
        if context.coordinator.currentStyle != mapStyle {
            context.coordinator.currentStyle = mapStyle
            context.coordinator.applyTileOverlay(to: map, style: mapStyle)
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
        var currentStyle: MapView.MapStyle = .osm
        private var tileOverlay: MKTileOverlay?

        /// Preset colors for the context menu color picker
        private static let colorPresets: [(name: String, hex: String)] = [
            (String(localized: "Red"),    "#FF0000"),
            (String(localized: "Blue"),   "#0000FF"),
            (String(localized: "Green"),  "#00FF00"),
            (String(localized: "Yellow"), "#FFD700"),
            (String(localized: "Orange"), "#FF8C00"),
            (String(localized: "Purple"), "#800080"),
            (String(localized: "Cyan"),   "#00CED1"),
            (String(localized: "Gray"),   "#808080"),
        ]

        init(_ parent: MeshMapViewRepresentable) {
            self.parent = parent
            self.currentStyle = parent.mapStyle
        }

        func applyTileOverlay(to map: MKMapView, style: MapView.MapStyle) {
            if let old = tileOverlay { map.removeOverlay(old) }
            let settings = SettingsService.shared
            let template: String
            switch style {
            case .osm:  template = settings.osmTileUrl
            case .topo: template = settings.osmTopoTileUrl
            case .dark: template = settings.osmDarkTileUrl
            }
            let overlay = CachedTileOverlay(urlTemplate: template, layer: style.rawValue)
            overlay.canReplaceMapContent = false
            map.addOverlay(overlay, level: .aboveRoads)
            tileOverlay = overlay
        }

        func updateNodes(_ map: MKMapView, nodes: [NodeInfo]) {
            let existingIds = Set(map.annotations.compactMap { ($0 as? NodeAnnotation)?.nodeId })
            let newIds = Set(nodes.compactMap { $0.latitude != nil ? $0.id : nil })

            // Remove stale
            for ann in map.annotations.compactMap({ $0 as? NodeAnnotation }) {
                if !newIds.contains(ann.nodeId) { map.removeAnnotation(ann) }
            }
            // Add/update
            for node in nodes {
                guard let lat = node.latitude, let lon = node.longitude else { continue }
                if let existing = map.annotations.first(where: { ($0 as? NodeAnnotation)?.nodeId == node.id }) as? NodeAnnotation {
                    existing.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    existing.title = node.name
                    // Update color in case it changed
                    existing.colorHex = node.colorHex
                } else {
                    let ann = NodeAnnotation(nodeId: node.id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    ann.title = node.name
                    ann.subtitle = node.nodeId
                    ann.colorHex = node.colorHex
                    map.addAnnotation(ann)
                }
                _ = existingIds
            }
        }

        // MARK: - Right-click context menu

        @objc func handleRightClick(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)

            // Find which annotation view was right-clicked
            guard let annotationView = findAnnotationView(at: point, in: mapView),
                  let nodeAnn = annotationView.annotation as? NodeAnnotation else { return }

            let nodeId = nodeAnn.nodeId
            let nodeName = nodeAnn.title ?? String(localized: "Node")

            // Build NSMenu
            let menu = NSMenu(title: nodeName)

            // Send Direct Message
            let dmItem = NSMenuItem(title: String(localized: "Send Direct Message"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            dmItem.target = self
            dmItem.representedObject = ContextMenuAction.sendDM(nodeId: nodeId)
            menu.addItem(dmItem)

            // Show Node Info
            let infoItem = NSMenuItem(title: String(localized: "Show Node Info"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            infoItem.target = self
            infoItem.representedObject = ContextMenuAction.showNodeInfo(nodeId: nodeId)
            menu.addItem(infoItem)

            menu.addItem(.separator())

            // Color picker submenu
            let colorMenu = NSMenu(title: String(localized: "Set Color"))
            for preset in Self.colorPresets {
                let colorItem = NSMenuItem(title: preset.name, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
                colorItem.target = self
                colorItem.representedObject = ContextMenuAction.setColor(nodeId: nodeId, hex: preset.hex)
                colorItem.image = createColorSwatch(hex: preset.hex)
                colorMenu.addItem(colorItem)
            }
            // Clear color option
            colorMenu.addItem(.separator())
            let clearColorItem = NSMenuItem(title: String(localized: "Clear Color"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            clearColorItem.target = self
            clearColorItem.representedObject = ContextMenuAction.setColor(nodeId: nodeId, hex: "")
            colorMenu.addItem(clearColorItem)

            let colorMenuItem = NSMenuItem(title: String(localized: "Set Color"), action: nil, keyEquivalent: "")
            colorMenuItem.submenu = colorMenu
            menu.addItem(colorMenuItem)

            // Set Note
            let noteItem = NSMenuItem(title: String(localized: "Set Note"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            noteItem.target = self
            noteItem.representedObject = ContextMenuAction.setNote(nodeId: nodeId)
            menu.addItem(noteItem)

            menu.addItem(.separator())

            // Set as My Position
            let posItem = NSMenuItem(title: String(localized: "Set as My Position"), action: #selector(contextMenuAction(_:)), keyEquivalent: "")
            posItem.target = self
            posItem.representedObject = ContextMenuAction.setAsMyPosition(nodeId: nodeId)
            menu.addItem(posItem)

            // Show the menu at the click location
            menu.popUp(positioning: nil, at: point, in: mapView)
        }

        /// Walk the view hierarchy to find the MKAnnotationView at a given point.
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

        /// Create a small color swatch NSImage for menu items.
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
            // Persist via UserDefaults
            SettingsService.shared.setColorHex(hex, for: nodeId)
            // Update in-memory model
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

            // Recalculate all distances from the new position
            parent.appState.recalculateAllDistances()
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

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

        /// When a node annotation is selected (left-click), show distance from
        /// "my position" in the callout subtitle using CLLocation.distance(from:).
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let nodeAnn = view.annotation as? NodeAnnotation else { return }

            let settings = SettingsService.shared
            let myLoc = CLLocation(latitude: settings.myLatitude, longitude: settings.myLongitude)
            let nodeLoc = CLLocation(latitude: nodeAnn.coordinate.latitude,
                                     longitude: nodeAnn.coordinate.longitude)
            let distanceMeters = myLoc.distance(from: nodeLoc)

            let distanceStr: String
            if distanceMeters < 1000 {
                distanceStr = String(format: "%.0f m", distanceMeters)
            } else {
                distanceStr = String(format: "%.1f km", distanceMeters / 1000)
            }

            // Show node ID + distance in subtitle
            let nodeIdStr = parent.appState.node(forId: nodeAnn.nodeId)?.nodeId ?? ""
            nodeAnn.subtitle = "\(nodeIdStr)  ·  \(distanceStr) \(String(localized: "away"))"
        }
    }
}

// MARK: - Context Menu Action

/// Wrapper class for passing action data through NSMenuItem.representedObject.
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
