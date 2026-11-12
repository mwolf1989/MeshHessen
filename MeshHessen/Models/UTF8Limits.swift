import Foundation

/// Firmware string limits are nanopb `max_size` values, i.e. UTF-8 **bytes**
/// (minus the terminating NUL), not characters. An umlaut takes two bytes and
/// an emoji up to four; a name over the limit makes the device discard the
/// whole admin write.
enum UTF8Limits {
    /// `ChannelSettings.name` (max_size 12).
    static let channelNameBytes = 11
    /// `User.short_name` (max_size 5).
    static let shortNameBytes = 4
    /// `User.long_name` (max_size 40) on firmware before 2.8.
    static let longNameBytesLegacy = 39
    /// Long-name limit enforced since firmware 2.8 (NodeInfoLite max_size 25).
    static let longNameBytesV28 = 24

    /// Long-name byte limit for a firmware version string such as `2.8.1.abc`.
    /// Unknown or unparsable versions fall back to the legacy limit.
    static func longNameBytes(firmwareVersion: String?) -> Int {
        guard let version = firmwareVersion,
              let (major, minor) = leadingMajorMinor(version)
        else { return longNameBytesLegacy }
        return (major, minor) >= (2, 8) ? longNameBytesV28 : longNameBytesLegacy
    }

    /// Parses the leading `^(\d+)\.(\d+)` of a version string.
    private static func leadingMajorMinor(_ version: String) -> (Int, Int)? {
        let parts = version.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let minorDigits = parts[1].prefix { $0.isASCII && $0.isNumber }
        guard !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              !minorDigits.isEmpty,
              let major = Int(parts[0]),
              let minor = Int(minorDigits)
        else { return nil }
        return (major, minor)
    }

    /// Truncates at a Character boundary so a composed grapheme or emoji is
    /// never split into invalid UTF-8.
    static func clamp(_ text: String, maxBytes: Int) -> String {
        guard !fits(text, maxBytes: maxBytes) else { return text }

        var result = ""
        var byteCount = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maxBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    static func fits(_ text: String, maxBytes: Int) -> Bool {
        text.utf8.count <= maxBytes
    }
}
