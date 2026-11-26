import SwiftUI

enum PFSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
    static let xxLarge: CGFloat = 28
    static let section: CGFloat = 36
}

enum PFRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 22
}

enum PFColor {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let accent = Color.accentColor
    static let income = Color(red: 0.20, green: 0.55, blue: 0.39)
    static let expense = Color(red: 0.78, green: 0.38, blue: 0.30)
    static let refund = Color(red: 0.10, green: 0.56, blue: 0.58)
    static let danger = Color(uiColor: .systemRed)

    static func category(_ token: String) -> Color {
        switch token {
        case "blue":
            Color(red: 0.25, green: 0.48, blue: 0.72)
        case "green":
            Color(red: 0.28, green: 0.57, blue: 0.42)
        case "orange":
            Color(red: 0.78, green: 0.49, blue: 0.24)
        case "purple":
            Color(red: 0.53, green: 0.42, blue: 0.68)
        default:
            Color(red: 0.20, green: 0.57, blue: 0.58)
        }
    }
}
