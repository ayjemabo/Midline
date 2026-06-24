import Foundation

enum PlayerPosition: String, Codable, CaseIterable, Identifiable {
    case goalkeeper
    case defender
    case midfielder
    case forward
    case utility

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

