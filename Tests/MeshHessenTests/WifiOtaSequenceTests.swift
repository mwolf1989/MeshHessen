import CryptoKit
import Foundation
import Testing

@testable import MeshHessen

/// Scripted loader: `readLine` returns the next scripted line, or times out when the script is empty.
/// Nothing touches the network.
actor ScriptedOtaStream: OtaByteStream {
    private var replies: [String]
    private(set) var sent: [Data] = []
    private(set) var closed = false

    init(replies: [String]) {
        self.replies = replies
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func readLine(timeout: Duration) async throws -> String {
        guard !replies.isEmpty else { throw WifiOtaError.timeout("\(timeout)") }
        return replies.removeFirst()
    }

    func close() async {
        closed = true
    }
}

private actor PhaseRecorder {
    private(set) var phases: [FirmwareTransferPhase] = []
    func record(_ phase: FirmwareTransferPhase) { phases.append(phase) }
}

@Suite("Wi-Fi OTA sequence")
struct WifiOtaSequenceTests {
    private static func image(size: Int) -> Data {
        Data((0..<size).map { UInt8($0 & 0xFF) })
    }

    private static func run(_ stream: ScriptedOtaStream, image: Data, recorder: PhaseRecorder? = nil) async throws {
        try await Esp32WifiOtaUpdater.run(
            stream: stream,
            image: image,
            chunkDelay: .zero,
            sleep: { _ in }
        ) { phase in
            await recorder?.record(phase)
        }
    }

    @Test("Happy path sends the start line and ceil(size/1024) chunks")
    func happyPath() async throws {
        let image = Self.image(size: 2500)
        let stream = ScriptedOtaStream(replies: ["ERASING", "ERASING", "OK", "OK"])
        let recorder = PhaseRecorder()

        try await Self.run(stream, image: image, recorder: recorder)

        let sent = await stream.sent
        #expect(sent.count == 1 + 3)
        let hash = Data(SHA256.hash(data: image))
        #expect(String(decoding: sent[0], as: UTF8.self) == UnifiedOta.startCommand(size: 2500, sha256: hash))
        #expect(sent.dropFirst().map(\.count) == [1024, 1024, 452])
        #expect(Data(sent.dropFirst().joined()) == image)

        let phases = await recorder.phases
        #expect(phases.filter { $0 == .erasing }.count == 2)
        #expect(phases.contains(.uploading(1)))
        #expect(phases.last == .validating)
    }

    @Test("An exact multiple of 1024 bytes needs no partial chunk")
    func exactChunks() async throws {
        let stream = ScriptedOtaStream(replies: ["OK", "OK"])
        try await Self.run(stream, image: Self.image(size: 4096))
        #expect(await stream.sent.count == 1 + 4)
    }

    @Test("ERR Hash Rejected after the start line aborts before any data is sent")
    func hashRejected() async throws {
        let stream = ScriptedOtaStream(replies: ["ERR Hash Rejected"])
        await #expect(throws: WifiOtaError.hashRejected) {
            try await Self.run(stream, image: Self.image(size: 3000))
        }
        #expect(await stream.sent.count == 1)
        #expect(WifiOtaError.hashRejected.localizedDescription.contains("hash"))
    }

    @Test("Other ERR lines during the handshake carry the loader's message")
    func handshakeError() async throws {
        let stream = ScriptedOtaStream(replies: ["ERASING", "ERR Partition too small"])
        await #expect(throws: WifiOtaError.loaderError("Partition too small")) {
            try await Self.run(stream, image: Self.image(size: 3000))
        }
    }

    @Test("A missing final OK is a timeout")
    func missingFinalOk() async throws {
        let stream = ScriptedOtaStream(replies: ["OK"])
        do {
            try await Self.run(stream, image: Self.image(size: 2048))
            Issue.record("Expected a timeout")
        } catch let error as WifiOtaError {
            guard case .timeout = error else {
                Issue.record("Expected .timeout, got \(error)")
                return
            }
        }
        #expect(await stream.sent.count == 1 + 2)
    }

    @Test("Late ACKs before the final OK are tolerated")
    func lateAckTolerated() async throws {
        let stream = ScriptedOtaStream(replies: ["OK", "ACK", "ACK", "OK"])
        try await Self.run(stream, image: Self.image(size: 1500))
        #expect(await stream.sent.count == 1 + 2)
    }

    @Test("ERR Hash Mismatch after the transfer is a verification failure")
    func hashMismatch() async throws {
        let stream = ScriptedOtaStream(replies: ["OK", "ACK", "ERR Hash Mismatch"])
        await #expect(throws: WifiOtaError.verificationFailed) {
            try await Self.run(stream, image: Self.image(size: 1500))
        }
    }

    @Test("An empty image is refused before anything is sent")
    func emptyImage() async throws {
        let stream = ScriptedOtaStream(replies: ["OK", "OK"])
        await #expect(throws: WifiOtaError.emptyImage) {
            try await Self.run(stream, image: Data())
        }
        #expect(await stream.sent.isEmpty)
    }

    @Test("ClientNotification classification follows Windows")
    func notificationClassification() {
        #expect(Esp32WifiOtaUpdater.classifyNotification("Rebooting to WiFi OTA") == .confirmed("Rebooting to WiFi OTA"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("Rebooting to BLE OTA") == .refused("Rebooting to BLE OTA"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("OTA not possible: no WiFi") == .refused("OTA not possible: no WiFi"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("Duty cycle limit reached") == nil)
        #expect(Esp32WifiOtaUpdater.classifyNotification("BOTANY") == nil)
    }
}

// MARK: - Full sequence with a fake device link

@MainActor
private final class FakeOtaLink {
    var answer: String?
    var sendResult = true
    var handler: ((String) -> Void)?
    var requestedHashes: [Data] = []
    var releaseCount = 0
    var beacon: String?
    var openedHosts: [String] = []
    var failingOpens = 0
    var stream = ScriptedOtaStream(replies: ["OK", "OK"])
    var handlerClearedAfterRun = false

    func dependencies() -> Esp32WifiOtaUpdater.Dependencies {
        Esp32WifiOtaUpdater.Dependencies(
            sendOtaRequest: { [unowned self] hash in
                requestedHashes.append(hash)
                if let answer { handler?(answer) }
                return sendResult
            },
            setNotificationHandler: { [unowned self] newHandler in
                handler = newHandler
                if newHandler == nil { handlerClearedAfterRun = true }
            },
            releaseMeshLink: { [unowned self] in releaseCount += 1 },
            discoverLoader: { [beacon] _ in beacon },
            openStream: { [unowned self] host in
                try await MainActor.run {
                    openedHosts.append(host)
                    if failingOpens > 0 {
                        failingOpens -= 1
                        throw WifiOtaError.loaderError("refused")
                    }
                }
                return await MainActor.run { stream }
            },
            sleep: { _ in },
            answerTimeout: .milliseconds(50)
        )
    }
}

@MainActor
@Suite("Wi-Fi OTA device sequence")
struct WifiOtaDeviceSequenceTests {
    private static let image = Data(repeating: 0xE9, count: 3000)

    private func perform(_ link: FakeOtaLink, knownHost: String? = nil) async throws {
        try await Esp32WifiOtaUpdater.perform(
            image: Self.image,
            knownHost: knownHost,
            dependencies: link.dependencies(),
            progress: { _ in },
            log: { _ in }
        )
    }

    @Test("Confirmed request, beacon found: releases the link and streams to the beacon sender")
    func confirmedWithBeacon() async throws {
        let link = FakeOtaLink()
        link.answer = "Rebooting to WiFi OTA"
        link.beacon = "192.168.1.50"

        try await perform(link, knownHost: "10.0.0.9")

        #expect(link.requestedHashes == [Data(SHA256.hash(data: Self.image))])
        #expect(link.releaseCount == 1)
        #expect(link.openedHosts == ["192.168.1.50"])
        #expect(await link.stream.sent.count == 1 + 3)
        #expect(await link.stream.closed)
        #expect(link.handlerClearedAfterRun)
    }

    @Test("A refusal stops before the link is released")
    func refusal() async throws {
        let link = FakeOtaLink()
        link.answer = "OTA not possible: WiFi not connected"
        await #expect(throws: WifiOtaError.otaRefused("OTA not possible: WiFi not connected")) {
            try await perform(link)
        }
        #expect(link.releaseCount == 0)
        #expect(link.openedHosts.isEmpty)
        #expect(link.handlerClearedAfterRun)
    }

    @Test("An unsent OTA request stops before the link is released")
    func requestNotSent() async throws {
        let link = FakeOtaLink()
        link.sendResult = false
        await #expect(throws: WifiOtaError.otaRequestNotSent) {
            try await perform(link)
        }
        #expect(link.releaseCount == 0)
    }

    @Test("Silence is consent; without a beacon the known TCP host is used")
    func silenceFallsBackToKnownHost() async throws {
        let link = FakeOtaLink()
        try await perform(link, knownHost: "meshnode.local")
        #expect(link.releaseCount == 1)
        #expect(link.openedHosts == ["meshnode.local"])
    }

    @Test("No beacon and no known host: loader not found")
    func loaderNotFound() async throws {
        let link = FakeOtaLink()
        await #expect(throws: WifiOtaError.loaderNotFound) {
            try await perform(link)
        }
        #expect(link.releaseCount == 1)
    }

    @Test("Connect retries up to ten times")
    func connectRetries() async throws {
        let link = FakeOtaLink()
        link.beacon = "192.168.1.50"
        link.failingOpens = 3
        try await perform(link)
        #expect(link.openedHosts.count == 4)

        let failing = FakeOtaLink()
        failing.beacon = "192.168.1.50"
        failing.failingOpens = 100
        do {
            try await perform(failing)
            Issue.record("Expected connectFailed")
        } catch let error as WifiOtaError {
            guard case .connectFailed(let attempts, _) = error else {
                Issue.record("Expected connectFailed, got \(error)")
                return
            }
            #expect(attempts == 10)
        }
        #expect(failing.openedHosts.count == 10)
    }
}
