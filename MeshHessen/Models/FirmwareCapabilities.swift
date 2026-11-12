import Foundation

/// Numeric prefix of a Meshtastic firmware version string such as "2.8.1.abc123".
/// Only `major.minor[.patch]` counts; anything after it (build hash, suffix) is ignored.
struct FirmwareVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the leading `^(\d+)\.(\d+)(\.(\d+))?` of the trimmed string; nil when it does not match.
    init?(_ string: String?) {
        guard let string else { return nil }
        var rest = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let major = Self.consumeNumber(&rest),
              rest.popFirst() == ".",
              let minor = Self.consumeNumber(&rest) else {
            return nil
        }
        var patch = 0
        if rest.first == "." {
            var afterDot = rest.dropFirst()
            patch = Self.consumeNumber(&afterDot) ?? 0
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    // MARK: - Private

    /// Removes leading ASCII digits from `rest` and returns their value; nil when there are none.
    private static func consumeNumber(_ rest: inout Substring) -> Int? {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        return value
    }
}

/// Feature gates by the connected device's firmware version.
/// Windows reference: `MeshhessenClient/Services/FirmwareCaps.cs`.
enum FirmwareCapabilities {
    /// True when `firmware` parses and is at least `major.minor.patch`; false when unparsable.
    static func atLeast(_ firmware: String?, _ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
        guard let version = FirmwareVersion(firmware) else { return false }
        return version >= FirmwareVersion(major: major, minor: minor, patch: patch)
    }

    static func supportsV28(_ firmware: String?) -> Bool {
        atLeast(firmware, 2, 8)
    }

    static func supportsEsp32Ota(_ firmware: String?) -> Bool {
        atLeast(firmware, 2, 7, 17)
    }
}
