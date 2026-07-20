import Foundation
import Testing

@testable import MeshHessen

@Suite("Update Checker")
struct UpdateCheckerTests {
    @Test("Semantic versions compare numeric components and prereleases")
    func semanticVersions() throws {
        let old = try #require(SemanticVersion("v1.0.18"))
        let patch = try #require(SemanticVersion("1.0.19"))
        let fourPart = try #require(SemanticVersion("1.5.14.2"))
        let prerelease = try #require(SemanticVersion("1.5.14.2-beta.1"))

        #expect(old < patch)
        #expect(patch < fourPart)
        #expect(prerelease < fourPart)
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
        #expect(SemanticVersion("not-a-version") == nil)
    }

    @Test("A newer stable GitHub release is returned")
    func newerStableRelease() async throws {
        let response = UpdateHTTPResponse(
            data: Data(
                """
                {
                  "tag_name": "v1.2.0",
                  "html_url": "https://github.com/mwolf1989/MeshHessen/releases/tag/v1.2.0",
                  "draft": false,
                  "prerelease": false,
                  "published_at": "2026-07-20T10:00:00Z"
                }
                """.utf8
            ),
            statusCode: 200
        )
        let client = StubUpdateHTTPClient(result: .success(response))
        let checker = UpdateChecker(httpClient: client)

        let update = await checker.checkForUpdate(currentVersion: "1.1.9")

        #expect(update?.version == SemanticVersion("1.2.0"))
        #expect(update?.releaseURL.host == "github.com")
        let request = await client.lastRequest
        #expect(request?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request?.timeoutInterval == 10)
    }

    @Test("Drafts, prereleases, old releases, bad responses, and offline errors stay silent")
    func ignoredResponses() async {
        let fixtures = [
            (releaseJSON(version: "2.0.0", draft: true, prerelease: false), 200),
            (releaseJSON(version: "2.0.0-beta", draft: false, prerelease: true), 200),
            (releaseJSON(version: "1.0.0", draft: false, prerelease: false), 200),
            ("not-json", 200),
            ("{}", 503),
        ]

        for (body, statusCode) in fixtures {
            let client = StubUpdateHTTPClient(
                result: .success(UpdateHTTPResponse(data: Data(body.utf8), statusCode: statusCode))
            )
            let checker = UpdateChecker(httpClient: client)
            #expect(await checker.checkForUpdate(currentVersion: "1.0.0") == nil)
        }

        let offlineClient = StubUpdateHTTPClient(result: .failure(.offline))
        let checker = UpdateChecker(httpClient: offlineClient)
        #expect(await checker.checkForUpdate(currentVersion: "1.0.0") == nil)
    }

    private func releaseJSON(version: String, draft: Bool, prerelease: Bool) -> String {
        """
        {
          "tag_name": "\(version)",
          "html_url": "https://github.com/mwolf1989/MeshHessen/releases/tag/v\(version)",
          "draft": \(draft),
          "prerelease": \(prerelease)
        }
        """
    }
}

private enum StubUpdateError: Error, Sendable {
    case offline
}

private actor StubUpdateHTTPClient: UpdateHTTPClient {
    private let result: Result<UpdateHTTPResponse, StubUpdateError>
    private(set) var lastRequest: URLRequest?

    init(result: Result<UpdateHTTPResponse, StubUpdateError>) {
        self.result = result
    }

    func get(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        lastRequest = request
        return try result.get()
    }
}
