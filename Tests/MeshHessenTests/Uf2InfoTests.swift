import Foundation
import Testing

@testable import MeshHessen

@Suite("UF2 boot drive")
struct Uf2InfoTests {
    private static let infoText = """
        UF2 Bootloader 0.9.2 lib/nrfx (v2.0.0) lib/tinyusb (0.12.0-145-g9775e7691) lib/uf2 (remotes/origin/configupdate-9-gadbb8c7)
        Model: WisBlock RAK4631 Board
        Board-ID: WisBlock-RAK4631-Board
        SoftDevice: S140 version 6.1.1
        Date: Dec 21 2021
        """

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-Uf2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("INFO_UF2.TXT fields are parsed")
    func parseInfo() {
        let info = Uf2VolumeFlasher.parseInfoUf2(Self.infoText)
        #expect(info.bootloaderVersion == "0.9.2")
        #expect(info.model == "WisBlock RAK4631 Board")
        #expect(info.boardId == "WisBlock-RAK4631-Board")
        #expect(info.softDevice == "S140 version 6.1.1")
    }

    @Test("Three-line RP2040 file, CRLF line ends and a v-prefixed version")
    func parseRp2040() {
        let text = "UF2 Bootloader v3.0\r\nModel: Raspberry Pi RP2\r\nBoard-ID: RPI-RP2\r\n"
        let info = Uf2VolumeFlasher.parseInfoUf2(text)
        #expect(info.bootloaderVersion == "3.0")
        #expect(info.model == "Raspberry Pi RP2")
        #expect(info.boardId == "RPI-RP2")
        #expect(info.softDevice == nil)
    }

    @Test("Unrelated text yields empty info")
    func parseGarbage() {
        #expect(Uf2VolumeFlasher.parseInfoUf2("hello\nworld") == Uf2BootloaderInfo())
    }

    @Test("readInfo needs INFO_UF2.TXT at the volume root")
    func readInfo() throws {
        let volume = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: volume) }
        #expect(Uf2VolumeFlasher.readInfo(atVolume: volume) == nil)
        try Self.infoText.write(
            to: volume.appendingPathComponent(Uf2VolumeFlasher.infoFileName),
            atomically: true,
            encoding: .utf8
        )
        #expect(Uf2VolumeFlasher.readInfo(atVolume: volume)?.boardId == "WisBlock-RAK4631-Board")
    }

    @Test("The copy writes the whole file onto the (temporary) volume root with progress")
    func copyToTemporaryVolume() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = directory.appendingPathComponent("FAKE-UF2", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("firmware-rak4631-2.7.26.uf2")
        let payload = Data((0..<(200 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: source)

        final class ProgressBox: @unchecked Sendable {
            let lock = NSLock()
            var values: [Double] = []
            func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
        }
        let box = ProgressBox()
        try await Uf2VolumeFlasher.copy(source, toVolume: volume) { box.add($0) }

        let copied = try Data(contentsOf: volume.appendingPathComponent(source.lastPathComponent))
        #expect(copied == payload)
        #expect(box.values.count == 4)
        #expect(box.values.last == 1)
    }

    @Test("A copy onto a missing volume fails with copyFailed")
    func copyFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("x.uf2")
        try Data(count: 1024).write(to: source)
        let missing = directory.appendingPathComponent("not-mounted", isDirectory: true)
        do {
            try await Uf2VolumeFlasher.copy(source, toVolume: missing) { _ in }
            Issue.record("Expected copyFailed")
        } catch let error as Uf2FlashError {
            guard case .copyFailed = error else {
                Issue.record("Expected copyFailed, got \(error)")
                return
            }
        }
    }

    @Test("Volume URLs compare by path")
    func sameVolume() {
        #expect(Uf2VolumeMonitor.same(URL(fileURLWithPath: "/Volumes/RAK4631/"), URL(fileURLWithPath: "/Volumes/RAK4631")))
        #expect(!Uf2VolumeMonitor.same(URL(fileURLWithPath: "/Volumes/RAK4631"), URL(fileURLWithPath: "/Volumes/RPI-RP2")))
    }
}
