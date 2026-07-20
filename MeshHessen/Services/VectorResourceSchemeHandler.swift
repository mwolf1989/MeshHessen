import Foundation
import WebKit

struct VectorResourceRequest: Equatable, Sendable {
    let remoteURL: URL
    let resourceType: VectorResourceType
}

enum VectorResourceURLCodec {
    static func encode(
        _ remoteURL: URL,
        resourceType: VectorResourceType = .unknown
    ) throws -> URL {
        guard let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              remoteURL.host?.isEmpty == false else {
            throw VectorTileCacheError.unsupportedRemoteURL
        }

        let encoded = Data(remoteURL.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = VectorResourceSchemeHandler.scheme
        components.host = "fetch"
        components.path = "/\(encoded)"
        components.queryItems = [URLQueryItem(name: "type", value: resourceType.rawValue)]
        guard let result = components.url else {
            throw VectorTileCacheError.unsupportedRemoteURL
        }
        return result
    }

    static func decode(_ url: URL) -> VectorResourceRequest? {
        guard url.scheme?.caseInsensitiveCompare(VectorResourceSchemeHandler.scheme) == .orderedSame,
              url.host?.caseInsensitiveCompare("fetch") == .orderedSame else {
            return nil
        }
        var encoded = String(url.path.drop(while: { $0 == "/" }))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8),
              let remoteURL = URL(string: value),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              remoteURL.host?.isEmpty == false else {
            return nil
        }
        let typeValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "type" })?
            .value
        return VectorResourceRequest(
            remoteURL: remoteURL,
            resourceType: VectorResourceType(mapLibreValue: typeValue)
        )
    }
}

/// Public WebKit entry point for MapLibre requests. Every in-flight scheme task
/// is represented by a Swift task so WebKit cancellation prevents all later
/// callbacks, as required by `WKURLSchemeHandler`.
@MainActor
final class VectorResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "meshhessen-resource"

    private let cache: VectorTileCacheService
    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(cache: VectorTileCacheService = .shared) {
        self.cache = cache
        super.init()
    }

    var activeRequestCount: Int { activeTasks.count }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resource = VectorResourceURLCodec.decode(requestURL) else {
            sendBadRequest(to: urlSchemeTask)
            return
        }

        let identifier = ObjectIdentifier(urlSchemeTask)
        activeTasks[identifier]?.cancel()
        activeTasks[identifier] = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await cache.response(
                    for: resource.remoteURL,
                    resourceType: resource.resourceType
                )
                try Task.checkCancellation()
                guard activeTasks[identifier] != nil else { return }
                deliver(response, requestURL: requestURL, to: urlSchemeTask)
                activeTasks.removeValue(forKey: identifier)
            } catch is CancellationError {
                // `stop` already removed the request. WebKit forbids callbacks now.
            } catch {
                guard activeTasks.removeValue(forKey: identifier) != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        activeTasks.removeValue(forKey: identifier)?.cancel()
    }

    private func deliver(
        _ response: VectorResourceResponse,
        requestURL: URL,
        to task: any WKURLSchemeTask
    ) {
        guard let http = HTTPURLResponse(
            url: requestURL,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(http)
        if let body = response.body, !body.isEmpty {
            task.didReceive(body)
        }
        task.didFinish()
    }

    private func sendBadRequest(to task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 400,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Access-Control-Allow-Origin": "*",
                    "Cross-Origin-Resource-Policy": "cross-origin",
                ]
              ) else {
            task.didFailWithError(VectorTileCacheError.unsupportedRemoteURL)
            return
        }
        task.didReceive(response)
        task.didFinish()
    }
}
