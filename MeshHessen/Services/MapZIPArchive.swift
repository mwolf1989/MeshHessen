import Foundation
import zlib

/// Small ZIP reader/writer used for portable map packages. The writer uses the
/// store method because PNG tiles are already compressed; the reader also
/// accepts the deflate method emitted by the Windows client.
enum MapZIPArchive {
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let maximumEntryCount = Int(UInt16.max)
    private static let maximumEntrySize = 128 * 1024 * 1024

    struct ExtractionResult: Sendable {
        let paths: [String]
        let totalBytes: Int64
    }

    static func create(from directory: URL, at archiveURL: URL) throws {
        let fileManager = FileManager.default
        let files = try regularFiles(in: directory, fileManager: fileManager)
        guard files.count <= maximumEntryCount else {
            throw OfflineMapError.packageTooLarge(files.count)
        }

        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        guard fileManager.createFile(atPath: archiveURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: archiveURL)
        defer { try? handle.close() }
        var offset: UInt32 = 0
        var entries: [CentralEntry] = []
        entries.reserveCapacity(files.count)

        for fileURL in files {
            let relativePath = try safeRelativePath(fileURL: fileURL, root: directory)
            let filename = Data(relativePath.utf8)
            guard filename.count <= Int(UInt16.max) else {
                throw OfflineMapError.archiveContainsUnsafePath
            }

            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Int(UInt32.max) else {
                throw OfflineMapError.packageTooLarge(files.count)
            }
            let checksum = crc32(for: data)
            let date = dosDate(for: (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date())

            var header = Data()
            header.appendLittleEndian(localHeaderSignature)
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(0x0800))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(date.time)
            header.appendLittleEndian(date.date)
            header.appendLittleEndian(checksum)
            header.appendLittleEndian(UInt32(data.count))
            header.appendLittleEndian(UInt32(data.count))
            header.appendLittleEndian(UInt16(filename.count))
            header.appendLittleEndian(UInt16(0))
            header.append(filename)

            try handle.write(contentsOf: header)
            try handle.write(contentsOf: data)

            entries.append(
                CentralEntry(
                    filename: filename,
                    crc32: checksum,
                    compressedSize: UInt32(data.count),
                    uncompressedSize: UInt32(data.count),
                    localHeaderOffset: offset,
                    time: date.time,
                    date: date.date
                )
            )
            offset += UInt32(header.count + data.count)
        }

        let centralOffset = offset
        for entry in entries {
            var header = Data()
            header.appendLittleEndian(centralHeaderSignature)
            header.appendLittleEndian(UInt16(0x0314))
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(0x0800))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(entry.time)
            header.appendLittleEndian(entry.date)
            header.appendLittleEndian(entry.crc32)
            header.appendLittleEndian(entry.compressedSize)
            header.appendLittleEndian(entry.uncompressedSize)
            header.appendLittleEndian(UInt16(entry.filename.count))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt32(0))
            header.appendLittleEndian(entry.localHeaderOffset)
            header.append(entry.filename)
            try handle.write(contentsOf: header)
            offset += UInt32(header.count)
        }

        var end = Data()
        end.appendLittleEndian(endSignature)
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(offset - centralOffset)
        end.appendLittleEndian(centralOffset)
        end.appendLittleEndian(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.synchronize()
    }

    static func extract(from archiveURL: URL, to destination: URL) throws -> ExtractionResult {
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let endOffset = try findEndRecord(in: archive)
        let entryCount = Int(try archive.readUInt16(at: endOffset + 10))
        let centralOffset = Int(try archive.readUInt32(at: endOffset + 16))
        guard entryCount <= maximumEntryCount, centralOffset >= 0, centralOffset < archive.count else {
            throw OfflineMapError.invalidPackage
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let canonicalDestination = destination.standardizedFileURL
        var cursor = centralOffset
        var paths: [String] = []
        var totalBytes: Int64 = 0

        for _ in 0..<entryCount {
            guard try archive.readUInt32(at: cursor) == centralHeaderSignature else {
                throw OfflineMapError.invalidPackage
            }
            let compression = try archive.readUInt16(at: cursor + 10)
            let checksum = try archive.readUInt32(at: cursor + 16)
            let compressedSize = Int(try archive.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(try archive.readUInt32(at: cursor + 24))
            let nameLength = Int(try archive.readUInt16(at: cursor + 28))
            let extraLength = Int(try archive.readUInt16(at: cursor + 30))
            let commentLength = Int(try archive.readUInt16(at: cursor + 32))
            let localOffset = Int(try archive.readUInt32(at: cursor + 42))
            let nameData = try archive.slice(at: cursor + 46, count: nameLength)
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw OfflineMapError.invalidPackage
            }
            cursor += 46 + nameLength + extraLength + commentLength

            guard !path.hasSuffix("/"), isSafeArchivePath(path) else { continue }
            guard uncompressedSize <= maximumEntrySize else {
                throw OfflineMapError.packageTooLarge(uncompressedSize)
            }
            guard try archive.readUInt32(at: localOffset) == localHeaderSignature else {
                throw OfflineMapError.invalidPackage
            }
            let localNameLength = Int(try archive.readUInt16(at: localOffset + 26))
            let localExtraLength = Int(try archive.readUInt16(at: localOffset + 28))
            let dataOffset = localOffset + 30 + localNameLength + localExtraLength
            let compressed = try archive.slice(at: dataOffset, count: compressedSize)

            let payload: Data
            switch compression {
            case 0:
                payload = compressed
            case 8:
                payload = try inflateRaw(compressed, expectedSize: uncompressedSize)
            default:
                throw OfflineMapError.unsupportedArchiveCompression(compression)
            }
            guard payload.count == uncompressedSize, crc32(for: payload) == checksum else {
                throw OfflineMapError.invalidPackage
            }

            let output = canonicalDestination.appendingPathComponent(path).standardizedFileURL
            guard output.path.hasPrefix(canonicalDestination.path + "/") else {
                throw OfflineMapError.archiveContainsUnsafePath
            }
            try fileManager.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: output, options: .atomic)
            paths.append(path)
            totalBytes += Int64(payload.count)
        }

        return ExtractionResult(paths: paths, totalBytes: totalBytes)
    }

    // MARK: - Helpers

    private struct CentralEntry {
        let filename: Data
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let time: UInt16
        let date: UInt16
    }

    private static func regularFiles(in directory: URL, fileManager: FileManager) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw OfflineMapError.packageNotFound
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func safeRelativePath(fileURL: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw OfflineMapError.archiveContainsUnsafePath
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard isSafeArchivePath(relative) else {
            throw OfflineMapError.archiveContainsUnsafePath
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else {
            return false
        }
        return !path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .contains("..")
    }

    private static func findEndRecord(in data: Data) throws -> Int {
        let minimum = max(0, data.count - 65_557)
        guard data.count >= 22 else { throw OfflineMapError.invalidPackage }
        for index in stride(from: data.count - 22, through: minimum, by: -1) {
            if try data.readUInt32(at: index) == endSignature {
                return index
            }
        }
        throw OfflineMapError.invalidPackage
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw OfflineMapError.invalidPackage }
        if expectedSize == 0 { return Data() }

        var output = Data(count: expectedSize)
        let status: Int32 = data.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let input = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let target = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_DATA_ERROR
                }
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer(mutating: input)
                stream.avail_in = uInt(data.count)
                stream.next_out = target
                stream.avail_out = uInt(expectedSize)

                let initialized = inflateInit2_(
                    &stream,
                    -MAX_WBITS,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                )
                guard initialized == Z_OK else { return initialized }
                defer { inflateEnd(&stream) }
                let result = inflate(&stream, Z_FINISH)
                guard result == Z_STREAM_END, stream.total_out == uLong(expectedSize) else {
                    return Z_DATA_ERROR
                }
                return Z_OK
            }
        }
        guard status == Z_OK else { throw OfflineMapError.invalidPackage }
        return output
    }

    private static func crc32(for data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, baseAddress, uInt(data.count)))
        }
    }

    private static func dosDate(for date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current,
            from: date
        )
        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))
        return (
            UInt16((hour << 11) | (minute << 5) | (second / 2)),
            UInt16(((year - 1980) << 9) | (month << 5) | day)
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) throws -> UInt16 {
        let bytes = try slice(at: offset, count: 2)
        return UInt16(bytes[bytes.startIndex])
            | UInt16(bytes[bytes.startIndex + 1]) << 8
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        let bytes = try slice(at: offset, count: 4)
        return UInt32(bytes[bytes.startIndex])
            | UInt32(bytes[bytes.startIndex + 1]) << 8
            | UInt32(bytes[bytes.startIndex + 2]) << 16
            | UInt32(bytes[bytes.startIndex + 3]) << 24
    }

    func slice(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count - count else {
            throw OfflineMapError.invalidPackage
        }
        return subdata(in: offset..<(offset + count))
    }
}
