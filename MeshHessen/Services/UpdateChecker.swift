import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    let numericComponents: [Int]
    let prereleaseIdentifiers: [String]

    init?(_ source: String) {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let versionAndPrerelease = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let numberStrings = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !numberStrings.isEmpty,
              numberStrings.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }

        let numbers = numberStrings.compactMap { Int($0) }
        guard numbers.count == numberStrings.count else { return nil }
        numericComponents = numbers

        if versionAndPrerelease.count == 2, !versionAndPrerelease[1].isEmpty {
            prereleaseIdentifiers = versionAndPrerelease[1].split(separator: ".").map(String.init)
        } else {
            prereleaseIdentifiers = []
        }
    }

    var description: String {
        let version = numericComponents.map(String.init).joined(separator: ".")
        guard !prereleaseIdentifiers.isEmpty else { return version }
        return version + "-" + prereleaseIdentifiers.joined(separator: ".")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
        for index in 0..<count {
            let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
            if left != right { return false }
        }
        return lhs.prereleaseIdentifiers == rhs.prereleaseIdentifiers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
        for index in 0..<count {
            let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
            if left != right { return left < right }
        }

        if lhs.prereleaseIdentifiers.isEmpty != rhs.prereleaseIdentifiers.isEmpty {
            return !lhs.prereleaseIdentifiers.isEmpty
        }

        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }
}

struct UpdateAvailability: Equatable, Sendable {
    let version: SemanticVersion
    let releaseURL: URL
    let publishedAt: Date?
}

struct UpdateHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol UpdateHTTPClient: Sendable {
    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse
}

struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            return UpdateHTTPResponse(data: data, statusCode: 0)
        }
        return UpdateHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

actor UpdateChecker {
    static let shared = UpdateChecker()
    static let releasesEndpoint: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/mwolf1989/MeshHessen/releases/latest"
        guard let url = components.url else {
            preconditionFailure("The built-in GitHub Releases URL is invalid")
        }
        return url
    }()

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case publishedAt = "published_at"
        }
    }

    private let httpClient: any UpdateHTTPClient
    private let endpoint: URL

    init(
        httpClient: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        endpoint: URL = UpdateChecker.releasesEndpoint
    ) {
        self.httpClient = httpClient
        self.endpoint = endpoint
    }

    /// Returns a newer stable release, or `nil` when current, offline, or the response is invalid.
    func checkForUpdate(currentVersion: String? = nil) async -> UpdateAvailability? {
        let installedVersionString = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        guard let installedVersion = SemanticVersion(installedVersionString) else { return nil }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MeshHessen/\(installedVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let response = try await httpClient.get(request)
            guard response.statusCode == 200 else { return nil }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: response.data)
            guard !release.draft,
                  !release.prerelease,
                  release.htmlURL.scheme == "https",
                  release.htmlURL.host?.lowercased() == "github.com",
                  let availableVersion = SemanticVersion(release.tagName),
                  availableVersion > installedVersion
            else {
                return nil
            }

            return UpdateAvailability(
                version: availableVersion,
                releaseURL: release.htmlURL,
                publishedAt: release.publishedAt
            )
        } catch {
            // Update checks are opportunistic. Offline and malformed responses stay silent.
            return nil
        }
    }
}
