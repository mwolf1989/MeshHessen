import Foundation
import Testing
import WebKit

@testable import MeshHessen

@Suite("Vector tile cache")
struct VectorTileCacheServiceTests {
    @Test("Resource URLs round-trip with query strings and MapLibre type")
    func resourceURLRoundTrip() throws {
        let remote = try #require(URL(
            string: "https://vectortile.meshhessenclient.de/fonts/Noto%20Sans/0-255.pbf?v=2&lang=de"
        ))
        let encoded = try VectorResourceURLCodec.encode(remote, resourceType: .glyphs)
        let decoded = try #require(VectorResourceURLCodec.decode(encoded))

        #expect(encoded.scheme == VectorResourceSchemeHandler.scheme)
        #expect(decoded.remoteURL == remote)
        #expect(decoded.resourceType == .glyphs)
        #expect(VectorResourceURLCodec.decode(URL(string: "https://example.test")!) == nil)
        #expect(throws: VectorTileCacheError.unsupportedRemoteURL) {
            try VectorResourceURLCodec.encode(URL(fileURLWithPath: "/tmp/style.json"))
        }
    }

    @Test("Cache paths distinguish queries while preserving useful extensions")
    func cachePathIncludesQuery() throws {
        let root = URL(fileURLWithPath: "/tmp/vector-cache-root", isDirectory: true)
        let first = try VectorTileCacheService.cacheFileURL(
            for: #require(URL(string: "https://example.test:8443/sprites/bright/sprite.png?v=1")),
            in: root
        )
        let second = try VectorTileCacheService.cacheFileURL(
            for: #require(URL(string: "https://example.test:8443/sprites/bright/sprite.png?v=2")),
            in: root
        )
        let extensionless = try VectorTileCacheService.cacheFileURL(
            for: #require(URL(string: "https://example.test/basemap")),
            in: root
        )

        #expect(first != second)
        #expect(first.pathExtension == "png")
        #expect(first.lastPathComponent.contains("__q_"))
        #expect(first.path.contains("example.test_8443"))
        #expect(extensionless.lastPathComponent == "basemap.bin")
        #expect(throws: VectorTileCacheError.unsupportedRemoteURL) {
            try VectorTileCacheService.cacheFileURL(
                for: URL(fileURLWithPath: "/etc/passwd"),
                in: root
            )
        }
    }

    @Test("Tiles are cache-first and requests use the MeshhessenClient identity")
    func cacheFirstAndUserAgent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = QueueVectorHTTPClient(responses: [
            .success(.init(
                data: Data([0x1A, 0x02, 0x08, 0x01]),
                statusCode: 200,
                reasonPhrase: "OK",
                headers: ["Content-Type": "application/vnd.mapbox-vector-tile"]
            )),
            .success(.init(
                data: Data("unexpected".utf8),
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [:]
            )),
        ])
        let service = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let url = try #require(URL(string: "https://vectortile.meshhessenclient.de/basemap/10/532/341"))

        let first = try await service.response(for: url, resourceType: .tile)
        let second = try await service.response(for: url, resourceType: .tile)

        #expect(first == second)
        #expect(first.mimeType == "application/vnd.mapbox-vector-tile")
        #expect(await client.requestCount == 1)
        let request = try #require(await client.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MeshhessenClient/") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("admin@meshhessenclient.de") == true)
    }

    @Test("Styles and TileJSON are network-first")
    func networkFirstResources() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = QueueVectorHTTPClient(responses: [
            .success(jsonResponse("{\"version\":8,\"name\":\"first\"}")),
            .success(jsonResponse("{\"version\":8,\"name\":\"second\"}")),
            .success(jsonResponse("{\"tiles\":[\"first\"]}")),
            .success(jsonResponse("{\"tiles\":[\"second\"]}")),
        ])
        let service = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let style = try #require(URL(string: "https://example.test/styles/osm.json"))
        let source = try #require(URL(string: "https://example.test/basemap"))

        _ = try await service.response(for: style, resourceType: .style)
        let refreshedStyle = try await service.response(for: style, resourceType: .style)
        _ = try await service.response(for: source, resourceType: .source)
        let refreshedSource = try await service.response(for: source, resourceType: .source)

        #expect(String(decoding: refreshedStyle.body ?? Data(), as: UTF8.self).contains("second"))
        #expect(String(decoding: refreshedSource.body ?? Data(), as: UTF8.self).contains("second"))
        #expect(await client.requestCount == 4)
        #expect(VectorTileCacheService.isNetworkFirst(style, resourceType: .unknown))
        #expect(VectorTileCacheService.isNetworkFirst(source, resourceType: .unknown))
    }

    @Test("Network errors fall back to stale style data")
    func staleOnError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{\"version\":8}".utf8)
        let client = QueueVectorHTTPClient(responses: [
            .success(.init(
                data: original,
                statusCode: 200,
                reasonPhrase: "OK",
                headers: ["Content-Type": "application/json"]
            )),
            .failure(StubVectorHTTPError.offline),
        ])
        let service = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let url = try #require(URL(string: "https://example.test/styles/osm.json"))

        _ = try await service.response(for: url, resourceType: .style)
        let stale = try await service.response(for: url, resourceType: .style)

        #expect(stale.statusCode == 200)
        #expect(stale.body == original)
        #expect(await client.requestCount == 2)
    }

    @Test("Offline mode serves cache only")
    func offlineMode() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = QueueVectorHTTPClient(responses: [
            .success(.init(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [:]
            )),
        ])
        let service = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let cachedURL = try #require(URL(string: "https://example.test/sprites/bright/sprite.png"))
        let missingURL = try #require(URL(string: "https://example.test/sprites/dark/sprite.png"))

        _ = try await service.response(for: cachedURL, resourceType: .spriteImage)
        await service.setOfflineOnly(true)
        let cached = try await service.response(for: cachedURL, resourceType: .spriteImage)
        let missing = try await service.response(for: missingURL, resourceType: .spriteImage)

        #expect(cached.statusCode == 200)
        #expect(cached.mimeType == "image/png")
        #expect(missing.statusCode == 404)
        #expect(missing.headers["Access-Control-Allow-Origin"] == "*")
        #expect(await client.requestCount == 1)
    }

    @Test("HTTP 204 and 404 create durable missing markers")
    func missingMarkers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = QueueVectorHTTPClient(responses: [
            .success(.init(data: Data(), statusCode: 204, reasonPhrase: "No Content", headers: [:])),
            .success(.init(data: Data(), statusCode: 404, reasonPhrase: "Not Found", headers: [:])),
        ])
        let service = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let noContentURL = try #require(URL(string: "https://example.test/basemap/10/1/1"))
        let notFoundURL = try #require(URL(string: "https://example.test/basemap/10/1/2"))

        #expect(try await service.response(for: noContentURL, resourceType: .tile).statusCode == 204)
        #expect(try await service.response(for: notFoundURL, resourceType: .tile).statusCode == 204)
        #expect(try await service.response(for: noContentURL, resourceType: .tile).statusCode == 204)
        #expect(try await service.response(for: notFoundURL, resourceType: .tile).statusCode == 204)
        #expect(await client.requestCount == 2)

        let firstMarker = try VectorTileCacheService.cacheFileURL(for: noContentURL, in: directory)
            .appendingPathExtension("missing")
        let secondMarker = try VectorTileCacheService.cacheFileURL(for: notFoundURL, in: directory)
            .appendingPathExtension("missing")
        #expect(FileManager.default.fileExists(atPath: firstMarker.path))
        #expect(FileManager.default.fileExists(atPath: secondMarker.path))
    }

    @Test("MIME detection covers JSON, sprites, WebP, and protobuf")
    func mimeAndCORS() async throws {
        #expect(VectorTileCacheService.contentType(
            for: URL(string: "https://example.test/style")!,
            data: Data("  {\"version\":8}".utf8)
        ) == "application/json")
        #expect(VectorTileCacheService.contentType(
            for: URL(string: "https://example.test/sprite")!,
            data: Data([0x89, 0x50, 0x4E, 0x47])
        ) == "image/png")
        #expect(VectorTileCacheService.contentType(
            for: URL(string: "https://example.test/sprite")!,
            data: Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
        ) == "image/webp")
        #expect(VectorTileCacheService.contentType(
            for: URL(string: "https://example.test/tiles/1/2/3")!,
            data: Data([0x1A, 0x02])
        ) == "application/vnd.mapbox-vector-tile")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-cache-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func jsonResponse(_ value: String) -> VectorHTTPClientResponse {
        .init(
            data: Data(value.utf8),
            statusCode: 200,
            reasonPhrase: "OK",
            headers: ["Content-Type": "application/json"]
        )
    }
}

@Suite("Vector WebKit scheme handler")
@MainActor
struct VectorResourceSchemeHandlerTests {
    @Test("Stopping a scheme task suppresses every late WebKit callback")
    func cancellationIsCallbackSafe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-scheme-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = DelayedVectorHTTPClient()
        let cache = VectorTileCacheService(cacheBaseDirectory: directory, httpClient: client)
        let handler = VectorResourceSchemeHandler(cache: cache)
        let remote = try #require(URL(string: "https://example.test/basemap/10/1/1"))
        let local = try VectorResourceURLCodec.encode(remote, resourceType: .tile)
        let task = RecordingSchemeTask(request: URLRequest(url: local))
        let webView = WKWebView(frame: .zero)

        handler.webView(webView, start: task)
        await Task.yield()
        handler.webView(webView, stop: task)
        try await Task.sleep(for: .milliseconds(50))

        #expect(handler.activeRequestCount == 0)
        #expect(task.callbackCount == 0)
        #expect(await client.requestCount <= 1)
    }

    @Test("Malformed local URLs receive a CORS-enabled 400 response")
    func malformedRequest() throws {
        let handler = VectorResourceSchemeHandler(cache: VectorTileCacheService())
        let url = try #require(URL(string: "meshhessen-resource://fetch/not-base64"))
        let task = RecordingSchemeTask(request: URLRequest(url: url))
        let webView = WKWebView(frame: .zero)

        handler.webView(webView, start: task)

        #expect(task.responses.first?.statusCode == 400)
        #expect(task.responses.first?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(task.didFinishCount == 1)
    }
}

private enum StubVectorHTTPError: Error, Sendable {
    case offline
}

private actor QueueVectorHTTPClient: VectorTileHTTPClient {
    private var responses: [Result<VectorHTTPClientResponse, StubVectorHTTPError>]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result<VectorHTTPClientResponse, StubVectorHTTPError>]) {
        self.responses = responses
    }

    var requestCount: Int { requests.count }

    func data(for request: URLRequest) async throws -> VectorHTTPClientResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw StubVectorHTTPError.offline }
        return try responses.removeFirst().get()
    }
}

private actor DelayedVectorHTTPClient: VectorTileHTTPClient {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> VectorHTTPClientResponse {
        requestCount += 1
        try await Task.sleep(for: .seconds(10))
        return .init(data: Data([0x01]), statusCode: 200, reasonPhrase: "OK", headers: [:])
    }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let lock = NSLock()
    private var storedResponses: [HTTPURLResponse] = []
    private var storedData: [Data] = []
    private var storedDidFinishCount = 0
    private var storedErrors: [Error] = []

    init(request: URLRequest) {
        self.request = request
    }

    var callbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedResponses.count + storedData.count + storedDidFinishCount + storedErrors.count
    }

    var responses: [HTTPURLResponse] {
        lock.lock()
        defer { lock.unlock() }
        return storedResponses
    }

    var didFinishCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDidFinishCount
    }

    func didReceive(_ response: URLResponse) {
        guard let response = response as? HTTPURLResponse else { return }
        lock.lock()
        storedResponses.append(response)
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func didFinish() {
        lock.lock()
        storedDidFinishCount += 1
        lock.unlock()
    }

    func didFailWithError(_ error: any Error) {
        lock.lock()
        storedErrors.append(error)
        lock.unlock()
    }
}
