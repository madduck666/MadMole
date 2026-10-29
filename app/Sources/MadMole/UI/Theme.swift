import AppKit
import SwiftUI

enum Theme {
    static let indigo = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    static let pink = Color(red: 1.00, green: 0.22, blue: 0.37)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.04)
    static let green = Color(red: 0.19, green: 0.78, blue: 0.35)
    static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let yellow = Color(red: 0.93, green: 0.68, blue: 0.00)
    static let gray = Color(red: 0.50, green: 0.52, blue: 0.58)
    static let red = Color(red: 1.00, green: 0.27, blue: 0.23)

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let cornerRadius: CGFloat = 14

    /// Green when healthy, orange when it needs attention, red when critical.
    static func level(_ fraction: Double, warn: Double = 0.70, critical: Double = 0.90) -> Color {
        if fraction >= critical { return red }
        if fraction >= warn { return orange }
        return green
    }

    static func health(_ score: Int) -> Color {
        if score >= 80 { return green }
        if score >= 60 { return yellow }
        if score >= 40 { return orange }
        return red
    }

    /// A soft backdrop tinted by the current page.
    static func backdrop(_ tint: Color) -> some View {
        LinearGradient(
            colors: [tint.opacity(0.10), Color.clear, Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
