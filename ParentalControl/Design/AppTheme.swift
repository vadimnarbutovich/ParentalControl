import SwiftUI

enum AppTheme {
    static let screenGradient = LinearGradient(
        colors: [
            Color(red: 0.04, green: 0.08, blue: 0.16),
            Color(red: 0.06, green: 0.16, blue: 0.28),
            Color(red: 0.12, green: 0.08, blue: 0.22),
            Color(red: 0.04, green: 0.06, blue: 0.13)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassBorder = Color.white.opacity(0.24)
    static let glassFill = Color.white.opacity(0.04)

    // Keep identical to ParentalControlDailyActivityReportView.reportBackground
    // in the report-extension target; opaque to cover the static loading hint.
    static let usageReportBackground = Color(red: 0.05, green: 0.08, blue: 0.17)

    static let neonGreen = Color(red: 0.25, green: 1.0, blue: 0.72)
    static let neonBlue = Color(red: 0.34, green: 0.76, blue: 1.0)
    static let neonOrange = Color(red: 1.0, green: 0.67, blue: 0.30)
    static let neonRed = Color(red: 1.0, green: 0.30, blue: 0.34)
    static let neonPurple = Color(red: 0.68, green: 0.49, blue: 1.0)
}
