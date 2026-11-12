import Foundation
import Testing

@testable import MeshHessen

@Suite("UTF8 Limits")
struct UTF8LimitTests {
    @Test("Umlauts count as two bytes")
    func umlautByteCount() {
        #expect("Hütte".utf8.count == 6)
        #expect(UTF8Limits.fits("Hütte", maxBytes: 6))
        #expect(!UTF8Limits.fits("Hütte", maxBytes: 5))
    }

    @Test("Clamping stops at the last whole character within the byte limit")
    func clampUmlauts() {
        let clamped = UTF8Limits.clamp("ÄÖÜÄÖÜ", maxBytes: 11)
        #expect(clamped == "ÄÖÜÄÖ")
        #expect(clamped.count == 5)
        #expect(clamped.utf8.count == 10)
    }

    @Test("Text within the limit is returned unchanged")
    func clampNoOp() {
        #expect(UTF8Limits.clamp("Mesh", maxBytes: UTF8Limits.shortNameBytes) == "Mesh")
        #expect(UTF8Limits.clamp("", maxBytes: UTF8Limits.channelNameBytes) == "")
    }

    @Test("An emoji is never split")
    func clampEmoji() {
        // "🚀" is 4 bytes; a family emoji is one Character of 25 bytes.
        #expect(UTF8Limits.clamp("ab🚀", maxBytes: 5) == "ab")
        #expect(UTF8Limits.clamp("ab🚀", maxBytes: 6) == "ab🚀")
        #expect(UTF8Limits.clamp("👨‍👩‍👧‍👦x", maxBytes: 11) == "")
        let clamped = UTF8Limits.clamp("Hi👋🏽 Mesh", maxBytes: 7)
        #expect(clamped == "Hi")
        #expect(String(decoding: Array(clamped.utf8), as: UTF8.self) == clamped)
    }

    @Test("Long-name limit depends on the firmware version")
    func longNameLimit() {
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "2.8.1.abc") == 24)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "2.8.0") == 24)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "3.0.0") == 24)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "2.7.26") == 39)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: nil) == 39)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "") == 39)
        #expect(UTF8Limits.longNameBytes(firmwareVersion: "unknown") == 39)
    }
}
