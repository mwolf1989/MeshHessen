import Foundation
import Testing

@testable import MeshHessen

/// Windows reference: MeshhessenClient.Tests/FirmwareUpdateTests.cs (file inspector + DFU package part).
@Suite("Firmware file inspector")
struct FirmwareFileInspectorTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirmwareFileInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fakeEspAppImage(chipId: UInt16, version: String, project: String, descriptor: Bool = true) -> Data {
        var image = Data(count: 1024)
        image[0] = FirmwareFileInspector.espImageMagic
        image[1] = 3
        image[12] = UInt8(chipId & 0xFF)
        image[13] = UInt8(chipId >> 8)
        if descriptor {
            writeUInt32LE(FirmwareFileInspector.espAppDescriptorMagic, into: &image, at: 0x20)
            image.replaceSubrange(0x30..<(0x30 + version.utf8.count), with: Data(version.utf8))
            image.replaceSubrange(0x50..<(0x50 + project.utf8.count), with: Data(project.utf8))
        }
        return image
    }

    private static func uf2Block(family: UInt32?, address: UInt32 = 0x26000) -> Data {
        var block = Data(count: 512)
        writeUInt32LE(FirmwareFileInspector.uf2MagicStart0, into: &block, at: 0)
        writeUInt32LE(FirmwareFileInspector.uf2MagicStart1, into: &block, at: 4)
        writeUInt32LE(family == nil ? 0 : FirmwareFileInspector.uf2FlagFamilyId, into: &block, at: 8)
        writeUInt32LE(address, into: &block, at: 12)
        writeUInt32LE(family ?? 0x1234, into: &block, at: 28)
        return block
    }

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 {
            data[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF)
        }
    }

    /// Builds a standard deflate ZIP with `/usr/bin/zip` from files written into `directory`.
    private static func makeZip(in directory: URL, name: String, files: [String: Data]) throws -> URL {
        let source = directory.appendingPathComponent("zip-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (fileName, data) in files {
            try data.write(to: source.appendingPathComponent(fileName))
        }
        let zipURL = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-9", zipURL.path] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zipURL
    }

    private static let heltecTarget = "heltec-v3"

    // MARK: - File names

    @Test(
        "File names match the Android rules",
        arguments: [
            ("firmware-heltec-v3-2.7.26.54e0d8d.bin", "heltec-v3", ".bin", true),
            ("firmware-heltec-v3-2.7.26.54e0d8d-update.bin", "heltec-v3", ".bin", true),
            ("firmware-heltec-v3-2.7.17.abc-update.bin", "heltec-v3", ".bin", true),
            ("firmware-tlora-v2-1-1_6-2.7.14.bin", "tlora-v2", ".bin", false),
            ("firmware-tlora-v2-2.7.14.bin", "tlora-v2", ".bin", true),
            ("firmware-heltec-v3-2.7.26.factory.bin", "heltec-v3", ".bin", false),
            ("littlefs-heltec-v3-2.7.26.bin", "heltec-v3", ".bin", false),
            ("bleota-s3.bin", "heltec-v3", ".bin", false),
            ("mt-esp32s3-ota.bin", "heltec-v3", ".bin", false),
            ("firmware-rak4631-2.7.26.54e0d8d-ota.zip", "rak4631", "-ota.zip", true),
            ("firmware-rak4631_eink-2.7.26-ota.zip", "rak4631", "-ota.zip", false),
            ("firmware-rak4631-2.7.26.uf2", "rak4631", ".uf2", true),
            ("sub/dir/firmware-rak4631-2.7.26.uf2", "rak4631", ".uf2", true),
            ("firmware-rak4631-2.7.26.uf2", "", ".uf2", false),
        ]
    )
    func fileNameRules(name: String, target: String, fileExtension: String, expected: Bool) {
        #expect(FirmwareFileInspector.isValidFirmwareFileName(name, target: target, fileExtension: fileExtension) == expected)
    }

    @Test("Version is taken from the file name")
    func versionFromFileName() {
        #expect(FirmwareFileInspector.versionFromFileName("firmware-heltec-v3-2.7.26.54e0d8d.bin") == "2.7.26.54e0d8d")
        #expect(FirmwareFileInspector.versionFromFileName("/x/firmware-rak4631-2.7.26.54e0d8d-ota.zip") == "2.7.26.54e0d8d")
        #expect(FirmwareFileInspector.versionFromFileName("firmware-heltec-v3-2.7.17.abc-update.bin") == "2.7.17.abc")
        #expect(FirmwareFileInspector.versionFromFileName("random.bin") == nil)
    }

    // MARK: - Headers

    @Test("ESP image header: chip id and application descriptor")
    func espHeader() {
        let image = Self.fakeEspAppImage(chipId: 0x0009, version: "2.7.26.54e0d8d", project: "firmware")
        #expect(FirmwareFileInspector.espImageChipId(image) == 0x0009)
        #expect(FirmwareFileInspector.hasEspAppDescriptor(image))
        #expect(FirmwareFileInspector.espAppVersion(image) == "2.7.26.54e0d8d")
        #expect(FirmwareFileInspector.espAppProjectName(image) == "firmware")
        #expect(EspChip.name(9) == "ESP32-S3")

        var bootloaderLike = Data(count: 1024)
        bootloaderLike[0] = 0xE9
        #expect(!FirmwareFileInspector.hasEspAppDescriptor(bootloaderLike))
        #expect(FirmwareFileInspector.espImageChipId(Data([0x00, 0x01])) == nil)
    }

    @Test("UF2 header: family id and first address")
    func uf2Header() {
        let block = Self.uf2Block(family: UF2Family.nrf52840)
        #expect(FirmwareFileInspector.isUF2(block))
        #expect(FirmwareFileInspector.uf2FamilyId(block) == UF2Family.nrf52840)
        #expect(FirmwareFileInspector.uf2FirstTargetAddress(block) == 0x26000)
        // Family flag cleared → offset 28 is a file size, not a family.
        #expect(FirmwareFileInspector.uf2FamilyId(Self.uf2Block(family: nil)) == nil)
        #expect(FirmwareFileInspector.uf2FamilyId(Data(count: 100)) == nil)
        #expect(FirmwareArchitecture.rp2040.uf2FamilyIds.contains(UF2Family.rp2040))
        #expect(FirmwareArchitecture.esp32s3.uf2FamilyIds.isEmpty)
    }

    // MARK: - inspect: ESP32

    @Test("Valid ESP32-S3 app image passes for S3 and fails for C3")
    func espChipCheck() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("firmware-heltec-v3-2.7.26.54e0d8d.bin")
        try Self.fakeEspAppImage(chipId: 0x0009, version: "2.7.26.54e0d8d", project: "firmware").write(to: url)

        let ok = FirmwareFileInspector.inspect(fileURL: url, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(ok.errors.isEmpty)
        #expect(ok.warnings.isEmpty)
        #expect(ok.detectedChip == "ESP32-S3")
        #expect(ok.detectedVersion == "2.7.26.54e0d8d")
        #expect(ok.items.contains(.chipOk("ESP32-S3")))
        #expect(ok.items.contains(.nameOk(target: "heltec-v3")))

        let wrong = FirmwareFileInspector.inspect(fileURL: url, expected: .esp32c3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(wrong.hasErrors)
        #expect(wrong.items.contains(.chipMismatch(found: "ESP32-S3", expected: "ESP32-C3")))
        #expect(wrong.errors.count == 1)
    }

    @Test("ESP image without app descriptor is reported as factory/bootloader image")
    func espWithoutDescriptor() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("firmware-heltec-v3-2.7.26.bin")
        try Self.fakeEspAppImage(chipId: 0x0009, version: "", project: "", descriptor: false).write(to: url)

        let result = FirmwareFileInspector.inspect(fileURL: url, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(result.items.contains(.notAppImage))
        #expect(result.hasErrors)
    }

    @Test("Factory, file-system and wrong-extension files are errors")
    func rejectedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Self.fakeEspAppImage(chipId: 0x0009, version: "2.7.26", project: "firmware")

        let factory = directory.appendingPathComponent("firmware-heltec-v3-2.7.26.factory.bin")
        try image.write(to: factory)
        #expect(FirmwareFileInspector.inspect(fileURL: factory, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
            .items.contains(.factoryImage))

        let littlefs = directory.appendingPathComponent("littlefs-heltec-v3-2.7.26.bin")
        try image.write(to: littlefs)
        let littlefsResult = FirmwareFileInspector.inspect(fileURL: littlefs, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(littlefsResult.items.contains(.notApplicationFile("littlefs-heltec-v3-2.7.26.bin")))
        #expect(littlefsResult.hasErrors)

        let wrongExtension = directory.appendingPathComponent("firmware-heltec-v3-2.7.26.uf2")
        try Data(count: 10).write(to: wrongExtension)
        #expect(FirmwareFileInspector.inspect(fileURL: wrongExtension, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
            .items == [.wrongExtension(expected: ".bin")])

        let notEsp = directory.appendingPathComponent("firmware-heltec-v3-2.7.26-update.bin")
        try Data(count: 100).write(to: notEsp)
        #expect(FirmwareFileInspector.inspect(fileURL: notEsp, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
            .items.contains(.notEspImage))

        // An ESP image offered for an nRF52 device is refused by kind.
        let forNrf = FirmwareFileInspector.inspect(fileURL: factory, expected: .nrf52840, kind: .espOtaBin, target: "rak4631")
        #expect(forNrf.items.contains(.kindNotSupported(kind: .espOtaBin, architecture: .nrf52840)))
    }

    @Test("Self-built image gets a custom-build hint instead of only a name warning")
    func customBuildHint() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("firmware.bin")
        try Self.fakeEspAppImage(chipId: 0x0009, version: "2.8.3.abcdef", project: "firmware").write(to: good)
        let result = FirmwareFileInspector.inspect(fileURL: good, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(!result.hasErrors)
        #expect(result.items.contains(.nameMismatch(target: "heltec-v3")))
        #expect(result.items.contains(.customBuildHint))
        #expect(result.detectedVersion == "2.8.3.abcdef")

        let bad = directory.appendingPathComponent("firmware2.bin")
        try Self.fakeEspAppImage(chipId: 0x0000, version: "2.8.3", project: "firmware").write(to: bad)
        let badResult = FirmwareFileInspector.inspect(fileURL: bad, expected: .esp32s3, kind: .espOtaBin, target: Self.heltecTarget)
        #expect(badResult.hasErrors)
        #expect(!badResult.items.contains(.customBuildHint))
    }

    @Test("Unknown architecture leaves the chip unverified as a warning")
    func unknownArchitectureWarns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("firmware-x-2.7.26.bin")
        try Self.fakeEspAppImage(chipId: 0x0005, version: "2.7.26", project: "firmware").write(to: url)
        let result = FirmwareFileInspector.inspect(fileURL: url, expected: .unknown, kind: .espOtaBin, target: nil)
        #expect(!result.hasErrors)
        #expect(result.items.contains(.chipUnverified(found: "ESP32-C3")))
        #expect(result.items.contains(.noTarget))
        #expect(result.warnings.count == 2)
    }

    // MARK: - inspect: UF2

    @Test("UF2 with nRF52840 family is OK for nRF52 and an error for RP2040")
    func uf2FamilyCheck() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("firmware-rak4631-2.7.26.uf2")
        try (Self.uf2Block(family: UF2Family.nrf52840) + Self.uf2Block(family: UF2Family.nrf52840)).write(to: url)

        let ok = FirmwareFileInspector.inspect(fileURL: url, expected: .nrf52840, kind: .uf2, target: "rak4631")
        #expect(!ok.hasErrors)
        #expect(ok.detectedChip == "nRF52840")
        #expect(ok.detectedVersion == "2.7.26")

        let wrong = FirmwareFileInspector.inspect(fileURL: url, expected: .rp2040, kind: .uf2, target: "rak4631")
        #expect(wrong.items.contains(.chipMismatch(found: "nRF52840", expected: "RP2040")))

        let noFamily = directory.appendingPathComponent("firmware-rak4631-2.7.27.uf2")
        try Self.uf2Block(family: nil).write(to: noFamily)
        #expect(FirmwareFileInspector.inspect(fileURL: noFamily, expected: .nrf52840, kind: .uf2, target: "rak4631")
            .items.contains(.uf2NoFamily))

        let notUf2 = directory.appendingPathComponent("firmware-rak4631-2.7.28.uf2")
        try Data(count: 600).write(to: notUf2)
        #expect(FirmwareFileInspector.inspect(fileURL: notUf2, expected: .nrf52840, kind: .uf2, target: "rak4631")
            .items.contains(.notUf2))
    }

    // MARK: - DFU package

    @Test("MapZIPArchive reads a deflate ZIP made by /usr/bin/zip")
    func mapZipReadsSystemZip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = Data(String(repeating: "Meshtastic DFU ", count: 200).utf8)  // compressible → deflate
        let zipURL = try Self.makeZip(in: directory, name: "fixture.zip", files: ["a.txt": text, "b.bin": Data([1, 2, 3])])

        let entries = try MapZIPArchive.readEntries(from: Data(contentsOf: zipURL), maximumEntrySize: 1024 * 1024)
        #expect(entries["a.txt"] == text)
        #expect(entries["b.bin"] == Data([1, 2, 3]))

        let filtered = try MapZIPArchive.readEntries(from: Data(contentsOf: zipURL), maximumEntrySize: 100)
        #expect(filtered.keys.sorted() == ["b.bin"])

        let extracted = directory.appendingPathComponent("out")
        let result = try MapZIPArchive.extract(from: zipURL, to: extracted)
        #expect(result.paths.sorted() == ["a.txt", "b.bin"])
        #expect(try Data(contentsOf: extracted.appendingPathComponent("a.txt")) == text)
    }

    @Test("DFU package exposes application and init packet, refuses bootloader-only packages")
    func dfuPackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initPacket = Data([1, 2, 3, 4])
        let firmware = Data((0..<300).map { UInt8($0 % 256) })

        let good = try Self.makeZip(in: directory, name: "firmware-rak4631-2.7.26-ota.zip", files: [
            "manifest.json": Data(#"{"manifest":{"application":{"bin_file":"firmware.bin","dat_file":"firmware.dat"}}}"#.utf8),
            "firmware.bin": firmware,
            "firmware.dat": initPacket,
        ])
        let package = try DfuPackage(zipURL: good)
        #expect(package.applicationBinary == firmware)
        #expect(package.initPacket == initPacket)
        #expect(package.binFileName == "firmware.bin")
        #expect(package.imageCount == 1)
        #expect(!package.hasSecureInitPacket)

        let inspection = FirmwareFileInspector.inspect(fileURL: good, expected: .nrf52840, kind: .nrfOtaZip, target: "rak4631")
        #expect(!inspection.hasErrors)
        #expect(inspection.items.contains(.dfuOk(binFile: "firmware.bin", size: 300)))

        let bootloader = try Self.makeZip(in: directory, name: "bootloader-ota.zip", files: [
            "manifest.json": Data(#"{"manifest":{"bootloader":{"bin_file":"bl.bin","dat_file":"bl.dat"}}}"#.utf8),
            "bl.bin": firmware,
            "bl.dat": initPacket,
        ])
        #expect(throws: DfuPackageError.noApplication(found: "bootloader")) {
            try DfuPackage(zipURL: bootloader)
        }
        #expect(FirmwareFileInspector.inspect(fileURL: bootloader, expected: .nrf52840, kind: .nrfOtaZip, target: "rak4631")
            .hasErrors)

        let missingBin = try Self.makeZip(in: directory, name: "missing.zip", files: [
            "manifest.json": Data(#"{"manifest":{"application":{"bin_file":"missing.bin","dat_file":"firmware.dat"}}}"#.utf8),
            "firmware.dat": initPacket,
        ])
        #expect(throws: DfuPackageError.missingEntry("missing.bin")) {
            try DfuPackage(zipURL: missingBin)
        }

        let noManifest = try Self.makeZip(in: directory, name: "nomanifest.zip", files: ["x.bin": firmware])
        #expect(throws: DfuPackageError.missingManifest) {
            try DfuPackage(zipURL: noManifest)
        }

        #expect(throws: DfuPackageError.self) {
            try DfuPackage(zipData: Data("not a zip".utf8))
        }
    }
}
