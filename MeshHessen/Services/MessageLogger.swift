import Foundation

/// Logs messages to per-channel and per-DM log files in
/// `~/Library/Application Support/MeshHessen/logs/`.
///
/// Log format:  `[YYYY-MM-DD HH:mm:ss] sender: message`
///
/// Also provides `load*` methods to restore previous messages on launch.
final class MessageLogger {
    static let shared = MessageLogger()

    let logsDir: URL
    private let queue = DispatchQueue(label: "msg-logger", qos: .background)

    /// Maximum lines kept per log file (older lines are trimmed on rotation).
    private let maxLinesPerFile = 5_000

    /// Maximum messages returned when loading history.
    private let defaultLoadLimit = 200

    // ISO-style formatter for log lines (includes date)
    private static let lineDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logsDir = support.appendingPathComponent("MeshHessen/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    // MARK: - Write

    func logChannelMessage(_ msg: MessageItem) {
        let fileName = channelFileName(index: msg.channelIndex, name: msg.channelName)
        append(line: formatLine(msg), to: fileName)
    }

    func logDirectMessage(_ msg: MessageItem, partnerName: String, partnerNodeId: UInt32) {
        let fileName = dmFileName(partnerNodeId: partnerNodeId, partnerName: partnerName)
        append(line: formatLine(msg), to: fileName)
    }

    // MARK: - Read (load history)

    /// Loads the last `limit` channel messages from the log file.
    func loadChannelMessages(channelIndex: Int, channelName: String, limit: Int? = nil) -> [MessageItem] {
        let fileName = channelFileName(index: channelIndex, name: channelName)
        return loadMessages(from: fileName, channelIndex: channelIndex, channelName: channelName, limit: limit ?? defaultLoadLimit)
    }

    /// Loads the last `limit` DM messages from the log file.
    func loadDirectMessages(partnerNodeId: UInt32, partnerName: String, limit: Int? = nil) -> [MessageItem] {
        let fileName = dmFileName(partnerNodeId: partnerNodeId, partnerName: partnerName)
        return loadMessages(from: fileName, channelIndex: 0, channelName: "", limit: limit ?? defaultLoadLimit)
    }

    /// Returns all DM log file names with their partner node IDs.
    /// Useful for discovering which conversations have history.
    func discoverDMLogFiles() -> [(nodeId: UInt32, name: String, fileName: String)] {
        var results: [(nodeId: UInt32, name: String, fileName: String)] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return results }
        for file in files where file.hasPrefix("DM_") && file.hasSuffix(".log") {
            // DM_{8-hex}_{name}.log
            let stripped = String(file.dropFirst(3).dropLast(4)) // remove "DM_" and ".log"
            guard stripped.count > 9 else { continue } // at least 8 hex + "_"
            let hexPart = String(stripped.prefix(8))
            let namePart = String(stripped.dropFirst(9)) // skip hex + "_"
            guard let nodeId = UInt32(hexPart, radix: 16) else { continue }
            results.append((nodeId: nodeId, name: namePart, fileName: file))
        }
        return results
    }

    /// Returns all channel log file names with their indices.
    func discoverChannelLogFiles() -> [(index: Int, name: String, fileName: String)] {
        var results: [(index: Int, name: String, fileName: String)] = []
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return results }
        for file in files where file.hasPrefix("Channel_") && file.hasSuffix(".log") {
            // Channel_{index}_{name}.log
            let stripped = String(file.dropFirst(8).dropLast(4)) // remove "Channel_" and ".log"
            guard let underscoreIdx = stripped.firstIndex(of: "_") else { continue }
            let indexStr = String(stripped[stripped.startIndex..<underscoreIdx])
            let namePart = String(stripped[stripped.index(after: underscoreIdx)...])
            guard let index = Int(indexStr) else { continue }
            results.append((index: index, name: namePart, fileName: file))
        }
        return results
    }

    // MARK: - Rotation

    /// Trims a log file to `maxLinesPerFile` if it exceeds that limit.
    /// Called periodically (e.g. on app launch or after many writes).
    func rotateIfNeeded() {
        queue.async { [self] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return }
            for file in files where file.hasSuffix(".log") {
                let url = logsDir.appendingPathComponent(file)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.count > maxLinesPerFile {
                    let trimmed = lines.suffix(maxLinesPerFile).joined(separator: "\n") + "\n"
                    try? trimmed.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Private: file naming

    private func channelFileName(index: Int, name: String) -> String {
        let safeName = name.isEmpty ? "Channel_\(index)" : name
        return "Channel_\(index)_\(sanitize(safeName)).log"
    }

    private func dmFileName(partnerNodeId: UInt32, partnerName: String) -> String {
        "DM_\(String(format: "%08x", partnerNodeId))_\(sanitize(partnerName)).log"
    }

    // MARK: - Private: formatting

    private func formatLine(_ msg: MessageItem) -> String {
        let timestamp = Self.lineDateFormatter.string(from: Date())
        return "[\(timestamp)] \(msg.from): \(msg.message)\n"
    }

    private func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined(separator: "_")
    }

    // MARK: - Private: file I/O

    private func append(line: String, to fileName: String) {
        let url = logsDir.appendingPathComponent(fileName)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let fh = try? FileHandle(forWritingTo: url) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Parses log lines from a file and returns `MessageItem` instances.
    /// Format: `[YYYY-MM-DD HH:mm:ss] sender: message`
    ///
    /// Falls back to legacy format `[HH:mm:ss] sender: message` for older log files.
    private func loadMessages(from fileName: String, channelIndex: Int, channelName: String, limit: Int) -> [MessageItem] {
        let url = logsDir.appendingPathComponent(fileName)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let rawLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let linesToParse = rawLines.suffix(limit)

        var messages: [MessageItem] = []
        for line in linesToParse {
            guard let parsed = parseLine(line, channelIndex: channelIndex, channelName: channelName) else { continue }
            messages.append(parsed)
        }
        return messages
    }

    /// Parses a single log line into a `MessageItem`.
    ///
    /// Supported formats:
    /// - `[2026-02-22 14:30:05] UserName: Hello world`
    /// - `[14:30:05] UserName: Hello world`  (legacy, no date)
    private func parseLine(_ line: String, channelIndex: Int, channelName: String) -> MessageItem? {
        // Must start with '['
        guard line.hasPrefix("[") else { return nil }
        guard let closeBracket = line.firstIndex(of: "]") else { return nil }

        let timestampStr = String(line[line.index(after: line.startIndex)..<closeBracket])

        // After "] " comes "sender: message"
        let afterBracket = line.index(closeBracket, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
        let rest = String(line[afterBracket...])

        guard let colonIdx = rest.firstIndex(of: ":") else { return nil }
        let sender = String(rest[rest.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let messageStart = rest.index(colonIdx, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.index(after: colonIdx)
        let messageText = String(rest[messageStart...]).trimmingCharacters(in: .whitespaces)

        // Extract display time: use just the time portion for display
        let displayTime: String
        if timestampStr.count > 10 {
            // "YYYY-MM-DD HH:mm:ss" → extract "HH:mm:ss"
            displayTime = String(timestampStr.suffix(8))
        } else {
            // Legacy "HH:mm:ss"
            displayTime = timestampStr
        }

        return MessageItem(
            time: displayTime,
            from: sender,
            fromId: 0,      // not recoverable from log
            toId: 0,         // not recoverable from log
            message: messageText,
            channelIndex: channelIndex,
            channelName: channelName
        )
    }
}
