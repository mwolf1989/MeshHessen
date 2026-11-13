import Foundation
import SwiftProtobuf
import Testing

@testable import MeshHessen

/// Windows reference: MeshhessenClient.Tests/FirmwareUpdateTests.cs (Unified OTA + admin message part).
@Suite("Unified OTA")
struct UnifiedOtaTests {
    @Test("Start command is OTA <size> <lowercase sha256 hex> and a newline")
    func startCommand() {
        #expect(UnifiedOta.startCommand(size: 1024, sha256: Data(count: 32))
            == "OTA 1024 " + String(repeating: "0", count: 64) + "\n")
        let hash = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let command = UnifiedOta.startCommand(size: 5, sha256: hash)
        #expect(command.hasPrefix("OTA 5 00070e15"))
        #expect(command.count == "OTA 5 ".count + 64 + 1)
    }

    @Test("Loader responses parse into their kinds")
    func parseResponses() {
        #expect(UnifiedOta.parse(line: "OK\n") == .ok(details: nil))
        #expect(UnifiedOta.parse(line: "OK 1 2.3.4 45 v2.3.4-abc123") == .ok(details: "1 2.3.4 45 v2.3.4-abc123"))
        #expect(UnifiedOta.parse(line: "ERASING\r\n") == .erasing)
        #expect(UnifiedOta.parse(line: "ACK") == .ack)
        #expect(UnifiedOta.parse(line: "ERR Hash Rejected") == .error("Hash Rejected"))
        #expect(UnifiedOta.parse(line: "ERR") == .error(""))
        #expect(UnifiedOta.parse(line: "WAT") == .unknown("WAT"))
        #expect(UnifiedOta.parse(line: "OKAY") == .unknown("OKAY"))

        let info = UnifiedOta.LoaderInfo(details: "1 2.3.4 45 v2.3.4-abc123")
        #expect(info?.firmwareVersion == "2.3.4")
        #expect(info?.rebootCount == 45)
        #expect(info?.gitHash == "v2.3.4-abc123")
        #expect(UnifiedOta.LoaderInfo(details: "1 2") == nil)
    }

    @Test("ota_request admin message carries mode, hash and session passkey")
    func otaRequestAdmin() throws {
        let hash = Data((0..<32).map(UInt8.init))
        let passkey = Data([1, 2, 3, 4])
        let admin = try #require(
            MeshtasticProtocolService.makeOtaRequestAdmin(mode: .otaWifi, sha256: hash, sessionPasskey: passkey)
        )
        let decoded = try Meshtastic_AdminMessage(serializedBytes: try admin.serializedData())
        #expect(decoded.otaRequest.rebootOtaMode == .otaWifi)
        #expect(decoded.otaRequest.otaHash == hash)
        #expect(decoded.sessionPasskey == passkey)

        #expect(MeshtasticProtocolService.makeOtaRequestAdmin(mode: .otaBle, sha256: Data(count: 5), sessionPasskey: passkey) == nil)
        #expect(MeshtasticProtocolService.makeOtaRequestAdmin(mode: .otaBle, sha256: hash, sessionPasskey: Data()) == nil)
    }

    @Test("enter_dfu_mode_request admin message carries the session passkey")
    func enterDfuAdmin() throws {
        let passkey = Data([9, 9])
        let admin = try #require(MeshtasticProtocolService.makeEnterDfuModeAdmin(sessionPasskey: passkey))
        let decoded = try Meshtastic_AdminMessage(serializedBytes: try admin.serializedData())
        #expect(decoded.enterDfuModeRequest)
        #expect(decoded.sessionPasskey == passkey)
        #expect(MeshtasticProtocolService.makeEnterDfuModeAdmin(sessionPasskey: Data()) == nil)
    }
}
