import Foundation
import Testing

@testable import MeshHessen

@Suite("Alert Bell")
struct AlertBellTests {
    @Test("Default alert text carries the BEL byte, the bell emoji and the default text")
    func defaultText() {
        let text = AlertBell.text("")
        #expect(text.hasPrefix("\u{0007}"))
        #expect(text.contains("🔔"))
        #expect(text.contains("Alert Bell Character!"))
    }

    @Test("Custom alert text is appended after the prefix")
    func customText() {
        #expect(AlertBell.text("Hilfe") == "\u{0007}🔔 Hilfe")
    }

    @Test("The first UTF-8 byte is the ASCII BEL control character")
    func firstByteIsBel() {
        #expect(Array(AlertBell.text("").utf8).first == 0x07)
        #expect(Array(AlertBell.text("Hilfe").utf8).first == 0x07)
    }
}
