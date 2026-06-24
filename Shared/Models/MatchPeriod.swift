import Foundation

enum MatchPeriod: String, Codable, CaseIterable, Identifiable {
    case firstHalf
    case secondHalf
    case extraTime
    case extraTimeFirstHalf
    case extraTimeSecondHalf
    case penalties
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstHalf: "1st Half"
        case .secondHalf: "2nd Half"
        case .extraTime: "Extra Time"
        case .extraTimeFirstHalf: "Extra Time 1"
        case .extraTimeSecondHalf: "Extra Time 2"
        case .penalties: "Penalties"
        case .finished: "Full Time"
        }
    }

    var shortTitle: String {
        switch self {
        case .firstHalf: "H1"
        case .secondHalf: "H2"
        case .extraTime: "ET"
        case .extraTimeFirstHalf: "ET1"
        case .extraTimeSecondHalf: "ET2"
        case .penalties: "P"
        case .finished: "FT"
        }
    }
}
