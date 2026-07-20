import Foundation
import Observation

actor EmergencyFeatureService {
    private static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")
        ?? URL(fileURLWithPath: "/")

    private let endpoint: URL
    private let session: URLSession
    private let cacheURL: URL
    private var cachedBounds: MapBounds?
    private var cachedAt: Date?
    private var cachedFeatures: [EmergencyMapFeature] = []

    init(
        endpoint: URL = EmergencyFeatureService.defaultEndpoint,
        session: URLSession = .shared,
        cacheURL: URL? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
    }

    func features(in bounds: MapBounds, forceRefresh: Bool = false) async throws -> [EmergencyMapFeature] {
        guard bounds.isValid else { throw OfflineMapError.invalidBounds }
        loadDiskCacheIfNeeded()
        if !forceRefresh,
           let cachedBounds,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < 15 * 60,
           Self.contains(cachedBounds, bounds) {
            return cachedFeatures
        }

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: Self.query(for: bounds))]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(MapTilePolicy.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw OfflineMapError.network(String(localized: "The fire and rescue layer could not be loaded."))
            }
            let decoded = try Self.decodeResponse(data)
            cachedBounds = bounds
            cachedAt = Date()
            cachedFeatures = decoded
            persistDiskCache()
            return decoded
        } catch {
            // Einsatzdaten should remain available without connectivity. A stale
            // snapshot is preferable to an empty layer and is clearly bounded.
            if let cachedBounds, Self.contains(cachedBounds, bounds), !cachedFeatures.isEmpty {
                return cachedFeatures
            }
            throw error
        }
    }

    nonisolated static func decodeResponse(_ data: Data) throws -> [EmergencyMapFeature] {
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap { element in
            guard let latitude = element.lat ?? element.center?.lat,
                  let longitude = element.lon ?? element.center?.lon else { return nil }
            let tags = element.tags ?? [:]
            let kind = featureKind(tags: tags)
            let name = tags["name"] ?? tags["operator"] ?? kind.localizedName
            let details = tags.filter { key, _ in
                [
                    "name", "ref", "access", "type", "fire_hydrant:type", "couplings",
                    "colour", "water_source", "flow_rate", "pressure", "water_volume",
                    "operator", "opening_hours", "location", "level", "survey_date", "check_date",
                ].contains(key)
            }
            return EmergencyMapFeature(
                id: "\(element.type)-\(element.id)",
                kind: kind,
                name: name,
                latitude: latitude,
                longitude: longitude,
                details: details
            )
        }
    }

    private nonisolated static func query(for bounds: MapBounds) -> String {
        let box = "\(bounds.south),\(bounds.west),\(bounds.north),\(bounds.east)"
        return """
        [out:json][timeout:25];
        (
          nwr["emergency"](\(box));
          nwr["amenity"~"fire_station|hospital|clinic|ambulance_station"](\(box));
          nwr["man_made"="siren"](\(box));
          nwr["rescue_station"](\(box));
        );
        out center tags;
        """
    }

    private nonisolated static func contains(_ outer: MapBounds, _ inner: MapBounds) -> Bool {
        outer.contains(latitude: inner.north, longitude: inner.west)
            && outer.contains(latitude: inner.south, longitude: inner.east)
    }

    private nonisolated static func featureKind(tags: [String: String]) -> EmergencyFeatureKind {
        switch tags["class"] {
        case "hydrant": return .hydrant
        case "defibrillator": return .defibrillator
        case "emergency_phone": return .emergencyPhone
        case "suction_point": return .suctionPoint
        case "water_tank": return .waterTank
        case "fire_water_pond": return .fireWaterPond
        case "siren": return .siren
        case "access_point": return .rescuePoint
        case "assembly_point": return .assemblyPoint
        case "fire_station": return .fireStation
        case "ambulance_station": return .rescueStation
        case "disaster_help_point": return .disasterHelpPoint
        case "mountain_rescue": return .mountainRescue
        case "landing_site": return .landingSite
        case "lifeguard": return .lifeguard
        case "ladder_site": return .ladderSite
        case "fire_service_inlet": return .fireServiceInlet
        case "fire_extinguisher": return .fireExtinguisher
        case "fire_alarm_box": return .fireAlarmBox
        case "fire_hose": return .fireHose
        case "key_depot": return .keyDepot
        case "life_ring": return .lifeRing
        case "first_aid_kit": return .firstAidKit
        default: break
        }
        switch tags["emergency"] {
        case "fire_hydrant": return .hydrant
        case "defibrillator": return .defibrillator
        case "phone": return .emergencyPhone
        case "suction_point": return .suctionPoint
        case "water_tank": return .waterTank
        case "fire_water_pond": return .fireWaterPond
        case "access_point": return .rescuePoint
        case "assembly_point": return .assemblyPoint
        case "disaster_help_point": return .disasterHelpPoint
        case "mountain_rescue": return .mountainRescue
        case "landing_site": return .landingSite
        case "lifeguard": return .lifeguard
        case "ladder_site": return .ladderSite
        case "fire_service_inlet": return .fireServiceInlet
        case "fire_extinguisher": return .fireExtinguisher
        case "fire_alarm_box": return .fireAlarmBox
        case "fire_hose": return .fireHose
        case "key_depot": return .keyDepot
        case "life_ring": return .lifeRing
        case "first_aid_kit": return .firstAidKit
        default: break
        }
        switch tags["amenity"] {
        case "fire_station": return .fireStation
        case "ambulance_station": return .rescueStation
        case "hospital", "clinic": return .hospital
        default: break
        }
        if tags["man_made"] == "siren" { return .siren }
        return .other
    }

    private func loadDiskCacheIfNeeded() {
        guard cachedFeatures.isEmpty,
              let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data)
        else { return }
        cachedBounds = snapshot.bounds
        cachedAt = snapshot.storedAt
        cachedFeatures = snapshot.features
    }

    private func persistDiskCache() {
        guard let cachedBounds, let cachedAt else { return }
        let snapshot = CacheSnapshot(bounds: cachedBounds, storedAt: cachedAt, features: cachedFeatures)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private nonisolated static var defaultCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("emergency-features.json")
    }

    private struct CacheSnapshot: Codable {
        let bounds: MapBounds
        let storedAt: Date
        let features: [EmergencyMapFeature]
    }

    private struct OverpassResponse: Decodable {
        let elements: [Element]
    }

    private struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
    }

    private struct Center: Decodable {
        let lat: Double
        let lon: Double
    }
}

@Observable
@MainActor
final class EmergencyFeatureStore {
    private let service: EmergencyFeatureService
    private var loadTask: Task<Void, Never>?

    private(set) var features: [EmergencyMapFeature] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(service: EmergencyFeatureService = EmergencyFeatureService()) {
        self.service = service
    }

    func refresh(bounds: MapBounds, zoom: Int, enabled: Bool) {
        loadTask?.cancel()
        guard enabled, zoom >= 13 else {
            isLoading = false
            return
        }

        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let loaded = try await service.features(in: bounds)
                try Task.checkCancellation()
                if features != loaded { features = loaded }
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
