import Foundation
import Testing

@testable import MeshHessen

@Suite("OTA beacon")
struct OtaBeaconTests {
    private func beacon(_ text: String) -> Bool {
        OtaBeaconListener.isBeacon(Data(text.utf8))
    }

    @Test("Loader beacons are recognised")
    func validBeacons() {
        #expect(beacon("Meshtastic_AB12 somehost"))
        #expect(beacon("Meshtastic_00FF 2.7.17\n"))
        // Windows accepts hex digits in either case (`[0-9A-Fa-f]`); the C# client is authoritative.
        #expect(beacon("Meshtastic_ab12 somehost"))
    }

    @Test("Other payloads are rejected")
    func invalidBeacons() {
        #expect(!beacon("Meshtastic_AB12"))
        #expect(!beacon("Meshtastic_AB12 "))
        #expect(!beacon("Meshtastic_AB1 host"))
        #expect(!beacon("Meshtastic_ZZ12 host"))
        #expect(!beacon("meshtastic_AB12 host"))
        #expect(!beacon("Meshtastic_AB12 host extra"))
        #expect(!beacon("Meshtastic_AB12 " + String(repeating: "x", count: 33)))
        #expect(!OtaBeaconListener.isBeacon(Data([0xFF, 0xFE, 0x00])))
        #expect(!beacon(""))
    }

    @Test("Port and IPv4 formatting")
    func ipv4Formatting() {
        #expect(OtaBeaconListener.port == 3232)
        let address = in_addr(s_addr: UInt32(0x3201A8C0)) // 192.168.1.50 in network byte order
        #expect(OtaBeaconListener.ipv4String(address) == "192.168.1.50")
    }
}
