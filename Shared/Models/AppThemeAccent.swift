import SwiftUI

enum AppThemeAccent: String, Codable, CaseIterable, Identifiable {
    case stadiumGreen
    case matchBlue
    case sunsetOrange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stadiumGreen:
            "Stadium Green"
        case .matchBlue:
            "Match Blue"
        case .sunsetOrange:
            "Sunset Orange"
        }
    }

    var color: Color {
        switch self {
        case .stadiumGreen: Color(red: 0.09, green: 0.63, blue: 0.38)
        case .matchBlue: Color(red: 0.10, green: 0.43, blue: 0.88)
        case .sunsetOrange: Color(red: 0.92, green: 0.44, blue: 0.18)
        }
    }
}
