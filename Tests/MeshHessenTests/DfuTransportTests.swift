import Foundation
import Testing

@testable import MeshHessen

private let noSleep: (Duration) async throws -> Void = { _ in }

@Suite("DFU protocol basics")
struct DfuProtocolTests {
    @Test("CRC-32 of the check string is 0xCBF43926")
    func crcKnownValue() {
        #expect(DfuCrc32.compute(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(DfuCrc32.compute(Data()) == 0)
    }

    @Test("Incremental CRC equals the one-shot CRC")
    func crcIncremental() {
        let data = dfuTestImage(10_000)
        var prefix = DfuPrefixCrc(data)
        #expect(prefix.crc(upTo: 4096) == DfuCrc32.compute(data.prefix(4096)))
        #expect(prefix.crc(upTo: 10_000) == DfuCrc32.compute(data))
        #expect(prefix.crc(upTo: 100) == DfuCrc32.compute(data.prefix(100)))
    }

    @Test("16-bit SIG UUIDs equal their 128-bit form")
    func gattUuidNormalisation() {
        #expect(GattUUID("0000FE59-0000-1000-8000-00805F9B34FB") == GattUUID("fe59"))
        #expect(GattUUID("00001530-1212-efde-1523-785feabcd123").value == "00001530-1212-EFDE-1523-785FEABCD123")
    }

    @Test("Secure responses parse select, checksum, failure with extended error")
    func secureParse() {
        let select = Data([0x60, 0x06, 0x01]) + DfuBytes.uint32LE(4096) + DfuBytes.uint32LE(512) + DfuBytes.uint32LE(0xAABB_CCDD)
        #expect(SecureDfuResponse.parse(select) == .select(maxSize: 4096, offset: 512, crc32: 0xAABB_CCDD))
        let checksum = Data([0x60, 0x03, 0x01]) + DfuBytes.uint32LE(100) + DfuBytes.uint32LE(7)
        #expect(SecureDfuResponse.parse(checksum) == .checksum(offset: 100, crc32: 7))
        #expect(SecureDfuResponse.parse(Data([0x60, 0x04, 0x0B, 0x0C])) == .failure(opcode: 0x04, result: 0x0B, extended: 0x0C))
        #expect(SecureDfuResponse.parse(Data([0x60, 0x06, 0x01])) == .failure(opcode: 0x06, result: SecureDfuResult.invalidParameter, extended: nil))
        #expect(SecureDfuResponse.parse(Data([0x10, 0x01])) == .unknown(Data([0x10, 0x01])))
    }

    @Test("Legacy responses and payloads")
    func legacyParse() {
        #expect(LegacyDfuResponse.parse(Data([0x10, 0x01, 0x01])) == .success(requestOpcode: 0x01))
        #expect(LegacyDfuResponse.parse(Data([0x10, 0x01, 0x02])) == .failure(requestOpcode: 0x01, status: 0x02))
        #expect(LegacyDfuResponse.parse(Data([0x11, 0x10, 0x27, 0, 0])) == .packetReceipt(bytesReceived: 10_000))
        #expect(LegacyDfuPayloads.imageSizes(application: 0x0102_0304) == Data([0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x03, 0x02, 0x01]))
        #expect(LegacyDfuPayloads.prnRequest(10) == Data([0x08, 0x0A, 0x00]))
    }

    @Test("Notification queue delivers in order, times out with nil and fails after close")
    func notificationQueue() async throws {
        let queue = GattNotificationQueue()
        queue.push(Data([1]))
        queue.push(Data([2]))
        #expect(try await queue.next(timeout: .milliseconds(10)) == Data([1]))
        #expect(try await queue.next(timeout: .milliseconds(10)) == Data([2]))
        #expect(try await queue.next(timeout: .milliseconds(10)) == nil)

        let waiting = Task { try await queue.next(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        queue.push(Data([3]))
        #expect(try await waiting.value == Data([3]))

        queue.close()
        await #expect(throws: FirmwareBleError.disconnected) { try await queue.next(timeout: .seconds(1)) }
    }
}

// MARK: - Legacy

@Suite("Legacy DFU transport")
struct LegacyDfuTransportTests {
    private static let initPacket = dfuTestImage(14, seed: 9)

    private func run(_ peer: LegacyBootloaderPeer, link: FakeDfuLink, firmware: Data, prn: Int = 10) async throws -> [FirmwareTransferPhase] {
        let transport = LegacyDfuTransport(link: link, prnInterval: prn, sleep: noSleep)
        try await transport.prepare()
        var phases: [FirmwareTransferPhase] = []
        try await transport.transfer(
            initPacket: Self.initPacket,
            firmware: firmware,
            phase: { phases.append($0) },
            progress: { _ in }
        )
        return phases
    }

    @Test("Happy path byte sequence")
    func happyPath() async throws {
        let peer = LegacyBootloaderPeer()
        let link = peer.makeLink(maxWriteLength: 182)
        let firmware = dfuTestImage(5000)

        let phases = try await run(peer, link: link, firmware: firmware)

        let expectedControl: [[UInt8]] = [[0x01, 0x04], [0x02, 0x00], [0x02, 0x01], [0x08, 0x0A, 0x00], [0x03], [0x04], [0x05]]
        #expect(peer.controlWrites.map { [UInt8]($0) } == expectedControl)
        #expect(peer.sizes == Data([0, 0, 0, 0, 0, 0, 0, 0]) + DfuBytes.uint32LE(5000))
        #expect(peer.initPacket == Self.initPacket)
        // Init packet in 20-byte pieces.
        let initWrites = link.writes(to: LegacyDfuUuids.packet).dropFirst().prefix(1)
        #expect(initWrites.first?.data.count == Self.initPacket.count)
        // 182 → 180 (multiple of 4); every packet but the last is 180 bytes.
        #expect(peer.firmwarePacketSizes.dropLast().allSatisfy { $0 == 180 })
        #expect(peer.firmwarePacketSizes.allSatisfy { $0 % 4 == 0 })
        #expect(peer.image == firmware)
        #expect(peer.activated)
        #expect(link.subscribed == [LegacyDfuUuids.controlPoint])
        #expect(link.writes(to: LegacyDfuUuids.packet).allSatisfy { !$0.withResponse })
        #expect(link.writes(to: LegacyDfuUuids.controlPoint).allSatisfy { $0.withResponse })
        #expect(phases.first == .preparingFlash)
        #expect(phases.contains(.sendingInitPacket))
        #expect(phases.last == .validating)
    }

    @Test("Packet size is clamped to 20…244 and rounded down to a multiple of 4")
    func packetSize() {
        #expect(LegacyDfuTransport.streamPacketSize(maxWriteLength: 20) == 20)
        #expect(LegacyDfuTransport.streamPacketSize(maxWriteLength: 10) == 20)
        #expect(LegacyDfuTransport.streamPacketSize(maxWriteLength: 182) == 180)
        #expect(LegacyDfuTransport.streamPacketSize(maxWriteLength: 509) == 244)
    }

    @Test("Init packet split into 20-byte writes")
    func initPacketPieces() async throws {
        let peer = LegacyBootloaderPeer()
        let link = peer.makeLink()
        let transport = LegacyDfuTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        let longInit = dfuTestImage(50, seed: 3)
        try await transport.transfer(initPacket: longInit, firmware: dfuTestImage(400), phase: { _ in }, progress: { _ in })
        let packetWrites = link.writes(to: LegacyDfuUuids.packet).map(\.data.count)
        #expect(Array(packetWrites[1...3]) == [20, 20, 10])
        #expect(peer.initPacket == longInit)
    }

    @Test("A receipt that disagrees with the bytes sent is an error")
    func receiptMismatch() async throws {
        let peer = LegacyBootloaderPeer()
        peer.receiptSkew = -4
        let link = peer.makeLink()
        await #expect(throws: DfuError.self) {
            _ = try await run(peer, link: link, firmware: dfuTestImage(5000))
        }
        #expect(!peer.activated)
        #expect(!peer.controlWrites.contains(Data([0x04])))
    }

    @Test("START answered with INVALID_STATE signals a stale session")
    func staleSession() async throws {
        let peer = LegacyBootloaderPeer()
        peer.startStatuses = [LegacyDfuStatus.invalidState]
        let link = peer.makeLink()
        await #expect(throws: DfuError.staleSession) {
            _ = try await run(peer, link: link, firmware: dfuTestImage(1000))
        }
        #expect(peer.controlWrites == [Data([0x01, 0x04])])
    }

    @Test("An init packet larger than 256 bytes is rejected before anything is written")
    func secureInitRejected() async throws {
        let peer = LegacyBootloaderPeer()
        let link = peer.makeLink()
        let transport = LegacyDfuTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        await #expect(throws: DfuError.self) {
            try await transport.transfer(initPacket: dfuTestImage(300), firmware: dfuTestImage(1000), phase: { _ in }, progress: { _ in })
        }
        #expect(link.writes.isEmpty)
    }

    @Test("A bootloader with DFU version below 5 is refused")
    func oldBootloader() async throws {
        let peer = LegacyBootloaderPeer()
        let link = peer.makeLink(version: Data([0x04, 0x00]))
        let transport = LegacyDfuTransport(link: link, sleep: noSleep)
        await #expect(throws: DfuError.self) { try await transport.prepare() }
    }

    @Test("A link drop mid-stream is reported as such")
    func midStreamDrop() async throws {
        let peer = LegacyBootloaderPeer()
        peer.dropAtPacket = 7
        let link = peer.makeLink()
        do {
            _ = try await run(peer, link: link, firmware: dfuTestImage(5000))
            Issue.record("Expected a mid-stream disconnect")
        } catch let error as DfuError {
            guard case .midStreamDisconnect = error else {
                Issue.record("Expected midStreamDisconnect, got \(error)")
                return
            }
        }
    }

    @Test("ABORT writes RESET (0x06)")
    func abort() async throws {
        let peer = LegacyBootloaderPeer()
        let link = peer.makeLink()
        let transport = LegacyDfuTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        await transport.abort()
        #expect(peer.resets == 1)
    }
}

// MARK: - Secure

@Suite("Secure DFU transport")
struct SecureDfuTransportTests {
    private static let initPacket = dfuTestImage(140, seed: 5)

    private func run(_ peer: SecureBootloaderPeer, firmware: Data, maxWriteLength: Int = 100) async throws -> FakeDfuLink {
        let link = peer.makeLink(maxWriteLength: maxWriteLength)
        let transport = SecureDfuTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        try await transport.transfer(initPacket: Self.initPacket, firmware: firmware, phase: { _ in }, progress: { _ in })
        return link
    }

    @Test("10 000-byte image with max object 4096 → objects of 4096/4096/1808")
    func objectSizes() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        _ = try await run(peer, firmware: firmware)
        #expect(peer.createdSizes[SecureDfuObjectType.command] == [Self.initPacket.count])
        #expect(peer.createdSizes[SecureDfuObjectType.data] == [4096, 4096, 1808])
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
        #expect(peer.received[SecureDfuObjectType.command] == Self.initPacket)
        #expect(peer.executed[SecureDfuObjectType.data] == 10_000)
        #expect(peer.prnValues == [0, 10])
    }

    @Test("Resume when SELECT reports a matching offset and CRC (partial object re-sent)")
    func resumePartialObject() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        peer.preload(type: SecureDfuObjectType.data, data: firmware.prefix(5000), executed: 4096)
        _ = try await run(peer, firmware: firmware)
        #expect(peer.createdSizes[SecureDfuObjectType.data] == [4096, 1808])
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
    }

    @Test("Resume at an object boundary executes the held object first")
    func resumeAtBoundary() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        peer.preload(type: SecureDfuObjectType.data, data: firmware.prefix(8192), executed: 4096)
        _ = try await run(peer, firmware: firmware)
        #expect(peer.createdSizes[SecureDfuObjectType.data] == [1808])
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
    }

    @Test("A held prefix with the wrong CRC is not resumed")
    func noResumeOnCrcMismatch() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        peer.preload(type: SecureDfuObjectType.data, data: dfuTestImage(5000, seed: 77), executed: 0)
        _ = try await run(peer, firmware: firmware)
        #expect(peer.createdSizes[SecureDfuObjectType.data] == [4096, 4096, 1808])
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
    }

    @Test("Lost packets: the missing tail is resent with PRN 1")
    func lostBytesResent() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        // Init packet: 2 packets (140 B at 100 B). Data object 1: packets 3…43; drop its last one.
        peer.dropPackets = [43]
        let link = try await run(peer, firmware: firmware)
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
        #expect(peer.prnValues == [0, 10, 1])
        #expect(peer.createdSizes[SecureDfuObjectType.data] == [4096, 4096, 1808])
        let dataPackets = link.writes(to: SecureDfuUuids.packet).map(\.data.count)
        #expect(dataPackets.contains(96))
    }

    @Test("A checksum mismatch retries the object")
    func checksumMismatchRetries() async throws {
        let peer = SecureBootloaderPeer()
        let firmware = dfuTestImage(10_000)
        peer.corruptChecksumNumber = 2  // first data object
        _ = try await run(peer, firmware: firmware)
        #expect(peer.received[SecureDfuObjectType.data] == firmware)
        #expect(peer.controlOpcodes.filter { $0 == SecureDfuOpcode.select }.count == 3)
    }

    @Test("EXECUTE INVALID_OBJECT is retried at once only for the last object")
    func executeRetryLastObjectOnly() async throws {
        let last = SecureBootloaderPeer()
        last.dataExecuteResults = [3: SecureDfuResult.invalidObject]
        let firmware = dfuTestImage(10_000)
        _ = try await run(last, firmware: firmware)
        let tail = Array(last.controlOpcodes.suffix(2))
        #expect(tail == [SecureDfuOpcode.execute, SecureDfuOpcode.execute])
        #expect(last.executed[SecureDfuObjectType.data] == 10_000)

        let first = SecureBootloaderPeer()
        first.dataExecuteResults = [1: SecureDfuResult.invalidObject]
        _ = try await run(first, firmware: firmware)
        // Not retried in place: the object transfer starts over with SELECT.
        let opcodes = first.controlOpcodes
        let failedIndex = try #require(opcodes.indices.first { index in
            opcodes[index] == SecureDfuOpcode.execute && opcodes[..<index].filter { $0 == SecureDfuOpcode.execute }.count == 1
        })
        #expect(opcodes[failedIndex + 1] == SecureDfuOpcode.select)
        #expect(first.received[SecureDfuObjectType.data] == firmware)
    }

    @Test("ABORT is 0x0C")
    func abort() async throws {
        let peer = SecureBootloaderPeer()
        let link = peer.makeLink()
        let transport = SecureDfuTransport(link: link, sleep: noSleep)
        try await transport.prepare()
        await transport.abort()
        #expect(peer.aborts == 1)
    }
}
