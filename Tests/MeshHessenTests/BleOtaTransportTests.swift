import CryptoKit
import Foundation
import Testing

@testable import MeshHessen

private let noSleep: (Duration) async throws -> Void = { _ in }

@Suite("BLE OTA transport")
struct BleOtaTransportTests {
    private func transfer(_ peer: BleOtaLoaderPeer, image: Data, maxWriteLength: Int = 244) async throws -> FakeDfuLink {
        let link = peer.makeLink(maxWriteLength: maxWriteLength)
        let transport = BleOtaTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        try await transport.start(size: image.count, sha256: Data(SHA256.hash(data: image))) {}
        try await transport.stream(image) { _ in }
        return link
    }

    @Test("Chunk size is min(512, maxWriteLength)")
    func chunkSize() {
        #expect(BleOtaTransport.chunkSize(maxWriteLength: 200) == 200)
        #expect(BleOtaTransport.chunkSize(maxWriteLength: 509) == 509)
        #expect(BleOtaTransport.chunkSize(maxWriteLength: 600) == 512)
        #expect(BleOtaTransport.chunkSize(maxWriteLength: 0) == 1)
    }

    @Test("Happy path: start line split to the write length, one write per chunk, one answer per chunk")
    func happyPath() async throws {
        let peer = BleOtaLoaderPeer()
        let image = dfuTestImage(5000)
        let link = try await transfer(peer, image: image, maxWriteLength: 600)

        let hash = Data(SHA256.hash(data: image)).map { String(format: "%02x", $0) }.joined()
        #expect(peer.command == "OTA 5000 \(hash)\n")
        #expect(peer.chunkSizes == [512, 512, 512, 512, 512, 512, 512, 512, 512, 392])
        #expect(peer.image == image)
        #expect(!peer.pacingViolation)
        #expect(link.subscribed == [BleOtaTransport.notifyUUID])
        #expect(link.pending(BleOtaTransport.notifyUUID) == 0)
    }

    @Test("A short write length splits the start line into with-response writes")
    func smallMtuStartLine() async throws {
        let peer = BleOtaLoaderPeer()
        let image = dfuTestImage(100)
        let link = try await transfer(peer, image: image, maxWriteLength: 20)
        let commandWrites = link.writes(to: BleOtaTransport.writeUUID).filter(\.withResponse)
        #expect(commandWrites.count == Int((Double(peer.command.utf8.count) / 20).rounded(.up)))
        #expect(commandWrites.allSatisfy { $0.data.count <= 20 })
        #expect(peer.chunkSizes == [20, 20, 20, 20, 20])
    }

    @Test("Every chunk waits for its own notification")
    func oneNotificationPerChunk() async throws {
        let peer = BleOtaLoaderPeer()
        let image = dfuTestImage(3000)
        _ = try await transfer(peer, image: image, maxWriteLength: 244)
        #expect(!peer.pacingViolation)
        #expect(peer.chunkSizes.count == 13)

        // A loader that stays silent after a chunk is a timeout, not a reason to send the next chunk.
        let silent = BleOtaLoaderPeer()
        let link = silent.makeLink()
        link.peer = { link, write in
            if write.withResponse { link.notify(BleOtaTransport.notifyUUID, Data("OK".utf8)) }
        }
        let transport = BleOtaTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        try await transport.start(size: image.count, sha256: Data(repeating: 1, count: 32)) {}
        await #expect(throws: BleOtaError.self) { try await transport.stream(image) { _ in } }
        #expect(link.writes(to: BleOtaTransport.writeUUID).filter { !$0.withResponse }.count == 1)
    }

    @Test("ACK for the last chunk, then the final OK")
    func ackThenOk() async throws {
        let peer = BleOtaLoaderPeer()
        peer.ackLastChunk = true
        let image = dfuTestImage(1000)
        _ = try await transfer(peer, image: image)
        #expect(peer.image == image)
    }

    @Test("OK before the last chunk is an error")
    func earlyOk() async throws {
        let peer = BleOtaLoaderPeer()
        peer.okAtChunk = 2
        await #expect(throws: BleOtaError.okBeforeLastChunk) {
            _ = try await transfer(peer, image: dfuTestImage(2000))
        }
        #expect(peer.chunkSizes.count == 2)
    }

    @Test("ERR Hash Mismatch is a verification failure")
    func hashMismatch() async throws {
        let peer = BleOtaLoaderPeer()
        peer.final = .hashMismatch
        await #expect(throws: WifiOtaError.verificationFailed) {
            _ = try await transfer(peer, image: dfuTestImage(1000))
        }
        let acked = BleOtaLoaderPeer()
        acked.final = .hashMismatch
        acked.ackLastChunk = true
        await #expect(throws: WifiOtaError.verificationFailed) {
            _ = try await transfer(acked, image: dfuTestImage(1000))
        }
    }

    @Test("ERR Hash Rejected during the handshake")
    func hashRejected() async throws {
        let peer = BleOtaLoaderPeer()
        peer.handshake = ["ERR Hash Rejected"]
        await #expect(throws: WifiOtaError.hashRejected) {
            _ = try await transfer(peer, image: dfuTestImage(1000))
        }
        #expect(peer.chunkSizes.isEmpty)
    }

    @Test("A loader without the OTA service is reported")
    func serviceMissing() async throws {
        let link = FakeDfuLink(maxWriteLength: 100, services: [:])
        let transport = BleOtaTransport(link: link, sleep: noSleep)
        await #expect(throws: BleOtaError.serviceMissing) { try await transport.prepare() }
    }
}

// MARK: - ESP32 BLE OTA sequence

@MainActor
private final class BleOtaHostFake {
    var answer: String?
    var sendResult = true
    var handler: ((String) -> Void)?
    var requested: [Data] = []
    var releaseCount = 0
    var rebootMarks = 0
    var connectAttempts = 0
    var failingConnects = 0
    var peer = BleOtaLoaderPeer()
    var links: [FakeDfuLink] = []

    func dependencies() -> Esp32BleOtaUpdater.Dependencies {
        Esp32BleOtaUpdater.Dependencies(
            sendOtaRequest: { [unowned self] hash in
                requested.append(hash)
                if let answer { handler?(answer) }
                return sendResult
            },
            setNotificationHandler: { [unowned self] in handler = $0 },
            markRebootRequested: { [unowned self] in rebootMarks += 1 },
            releaseMeshLink: { [unowned self] in releaseCount += 1 },
            connectLoader: { [unowned self] in
                try await MainActor.run {
                    connectAttempts += 1
                    if failingConnects > 0 {
                        failingConnects -= 1
                        throw FirmwareBleError.peripheralNotFound
                    }
                }
                return await MainActor.run {
                    let link = peer.makeLink()
                    links.append(link)
                    return link
                }
            },
            sleep: { _ in },
            answerTimeout: .milliseconds(50)
        )
    }
}

@MainActor
@Suite("BLE OTA device sequence")
struct BleOtaDeviceSequenceTests {
    private static let image = dfuTestImage(3000)

    private func perform(_ host: BleOtaHostFake) async throws {
        try await Esp32BleOtaUpdater.perform(image: Self.image, dependencies: host.dependencies(), progress: { _ in }, log: { _ in })
    }

    @Test("Firmware confirmations are classified per mode")
    func classification() {
        #expect(Esp32WifiOtaUpdater.classifyNotification("Rebooting to BLE OTA", mode: .ble) == .confirmed("Rebooting to BLE OTA"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("Rebooting to WiFi OTA", mode: .ble) == .refused("Rebooting to WiFi OTA"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("Rebooting to BLE OTA", mode: .wifi) == .refused("Rebooting to BLE OTA"))
        #expect(Esp32WifiOtaUpdater.classifyNotification("Battery low", mode: .ble) == nil)
    }

    @Test("Confirmed: marks the reboot, releases the link, streams to the loader and closes it")
    func confirmed() async throws {
        let host = BleOtaHostFake()
        host.answer = "Rebooting to BLE OTA"
        try await perform(host)
        #expect(host.requested == [Data(SHA256.hash(data: Self.image))])
        #expect(host.rebootMarks == 1)
        #expect(host.releaseCount == 1)
        #expect(host.connectAttempts == 1)
        #expect(host.peer.image == Self.image)
        #expect(host.links.first?.disconnectCount == 1)
        #expect(host.handler == nil)
    }

    @Test("A refusal keeps the link and never marks a reboot")
    func refused() async throws {
        let host = BleOtaHostFake()
        host.answer = "OTA not possible: no partition"
        await #expect(throws: WifiOtaError.otaRefused("OTA not possible: no partition")) { try await perform(host) }
        #expect(host.rebootMarks == 0)
        #expect(host.releaseCount == 0)
        #expect(host.connectAttempts == 0)
    }

    @Test("An unsent request stops before anything else")
    func notSent() async throws {
        let host = BleOtaHostFake()
        host.sendResult = false
        await #expect(throws: WifiOtaError.otaRequestNotSent) { try await perform(host) }
        #expect(host.rebootMarks == 0)
        #expect(host.releaseCount == 0)
    }

    @Test("Connect retries up to five times")
    func connectRetries() async throws {
        let host = BleOtaHostFake()
        host.failingConnects = 2
        try await perform(host)
        #expect(host.connectAttempts == 3)

        let failing = BleOtaHostFake()
        failing.failingConnects = 100
        await #expect(throws: BleOtaError.connectFailed(attempts: 5, reason: FirmwareBleError.peripheralNotFound.localizedDescription)) {
            try await perform(failing)
        }
        #expect(failing.connectAttempts == 5)
        #expect(failing.rebootMarks == 1)
    }

    @Test("A loader failure still closes the Bluetooth link")
    func failureClosesLink() async throws {
        let host = BleOtaHostFake()
        host.peer.final = .hashMismatch
        await #expect(throws: WifiOtaError.verificationFailed) { try await perform(host) }
        #expect(host.links.first?.disconnectCount == 1)
    }
}
