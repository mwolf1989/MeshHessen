import Foundation
import Testing

@testable import MeshHessen

@Suite("Firmware Capabilities")
struct FirmwareCapabilitiesTests {
    @Test("Version strings parse their numeric prefix only")
    func parsing() {
        let withHash = FirmwareVersion("2.8.1.abcdef")
        #expect(withHash?.major == 2)
        #expect(withHash?.minor == 8)
        #expect(withHash?.patch == 1)

        let withoutPatch = FirmwareVersion("2.8")
        #expect(withoutPatch?.minor == 8)
        #expect(withoutPatch?.patch == 0)

        #expect(FirmwareVersion("2.8x.1") == FirmwareVersion(major: 2, minor: 8))
        #expect(FirmwareVersion(" 2.7.26 ") == FirmwareVersion(major: 2, minor: 7, patch: 26))
    }

    @Test("Firmware 2.8 gate")
    func supportsV28() {
        #expect(FirmwareCapabilities.supportsV28("2.8.1.abcdef"))
        #expect(FirmwareCapabilities.supportsV28("2.8.0"))
        #expect(FirmwareCapabilities.supportsV28("3.0.0"))
        #expect(!FirmwareCapabilities.supportsV28("2.7.26"))
    }

    @Test("ESP32 OTA gate starts at 2.7.17")
    func supportsEsp32Ota() {
        #expect(FirmwareCapabilities.supportsEsp32Ota("2.7.17"))
        #expect(FirmwareCapabilities.supportsEsp32Ota("2.7.17.abc123"))
        #expect(FirmwareCapabilities.supportsEsp32Ota("2.8.0"))
        #expect(!FirmwareCapabilities.supportsEsp32Ota("2.7.16"))
        #expect(!FirmwareCapabilities.supportsEsp32Ota("2.6.99"))
    }

    @Test("Missing or unparsable versions never pass a gate")
    func unparsable() {
        for firmware in [nil, "", "garbage", "2", "2.", ".8.1", "v2.8.1"] as [String?] {
            #expect(FirmwareVersion(firmware) == nil)
            #expect(!FirmwareCapabilities.atLeast(firmware, 0, 0))
            #expect(!FirmwareCapabilities.supportsV28(firmware))
            #expect(!FirmwareCapabilities.supportsEsp32Ota(firmware))
        }
    }

    @Test("Comparison orders major, then minor, then patch")
    func ordering() {
        #expect(FirmwareVersion(major: 2, minor: 7, patch: 30) < FirmwareVersion(major: 2, minor: 8))
        #expect(FirmwareVersion(major: 1, minor: 99, patch: 99) < FirmwareVersion(major: 2, minor: 0))
        #expect(FirmwareVersion(major: 2, minor: 8, patch: 1) > FirmwareVersion(major: 2, minor: 8, patch: 0))
    }
}
