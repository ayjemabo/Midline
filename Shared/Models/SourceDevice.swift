import Foundation

enum SourceDevice: String, Codable, CaseIterable {
    case iPhone
    case watch

    var displayTitle: String {
        switch self {
        case .iPhone:
            "iPhone"
        case .watch:
            "Watch"
        }
    }
}
