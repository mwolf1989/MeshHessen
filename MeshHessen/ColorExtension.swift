import SwiftUI
import AppKit

// MARK: - Color hex initializer (shared across all views)
extension Color {
    /// Creates a Color from a CSS hex string like "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let rgb = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >>  8) & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}
