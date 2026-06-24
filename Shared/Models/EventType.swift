import Foundation
import SwiftUI

enum MatchEventType: String, Codable, CaseIterable, Identifiable {
    case goal
    case ownGoal
    case shotOnTarget
    case shotOffTarget
    case assist
    case keyPass
    case tackleWon
    case interception
    case clearance
    case save
    case foulCommitted
    case foulWon
    case yellowCard
    case redCard
    case cornerWon
    case offside
    case dribbleCompleted
    case possessionLost
    case substitution
    case penaltyScored
    case penaltyMissed
    case penaltySaved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goal: "Goal"
        case .ownGoal: "Own Goal"
        case .shotOnTarget: "Shot On"
        case .shotOffTarget: "Shot Off"
        case .assist: "Assist"
        case .keyPass: "Key Pass"
        case .tackleWon: "Tackle Won"
        case .interception: "Interception"
        case .clearance: "Clearance"
        case .save: "Save"
        case .foulCommitted: "Foul Committed"
        case .foulWon: "Foul Won"
        case .yellowCard: "Yellow Card"
        case .redCard: "Red Card"
        case .cornerWon: "Corner Won"
        case .offside: "Offside"
        case .dribbleCompleted: "Dribble Completed"
        case .possessionLost: "Possession Lost"
        case .substitution: "Substitution"
        case .penaltyScored: "Penalty Scored"
        case .penaltyMissed: "Penalty Missed"
        case .penaltySaved: "Penalty Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .goal: "soccerball"
        case .ownGoal: "soccerball.inverse"
        case .shotOnTarget: "scope"
        case .shotOffTarget: "scope"
        case .assist: "figure.2"
        case .keyPass: "arrow.forward.circle"
        case .tackleWon: "shield.lefthalf.filled"
        case .interception: "hand.raised"
        case .clearance: "wind"
        case .save: "hand.raised.circle"
        case .foulCommitted: "exclamationmark.triangle"
        case .foulWon: "flag"
        case .yellowCard: "rectangle.fill"
        case .redCard: "rectangle.fill"
        case .cornerWon: "flag.pattern.checkered"
        case .offside: "line.3.crossed.swirl.circle"
        case .dribbleCompleted: "figure.run"
        case .possessionLost: "arrow.uturn.backward.circle"
        case .substitution: "arrow.left.arrow.right.circle"
        case .penaltyScored: "checkmark.circle"
        case .penaltyMissed: "xmark.circle"
        case .penaltySaved: "hand.raised.circle"
        }
    }

    var tint: Color {
        switch self {
        case .goal: .green
        case .ownGoal: .red
        case .shotOnTarget: .blue
        case .shotOffTarget: .orange
        case .assist: .mint
        case .keyPass: .cyan
        case .tackleWon: .teal
        case .interception: .indigo
        case .clearance: .brown
        case .save: .blue
        case .foulCommitted: .orange
        case .foulWon: .mint
        case .yellowCard: .yellow
        case .redCard: .red
        case .cornerWon: .purple
        case .offside: .gray
        case .dribbleCompleted: .pink
        case .possessionLost: .secondary
        case .substitution: .indigo
        case .penaltyScored: .green
        case .penaltyMissed: .orange
        case .penaltySaved: .blue
        }
    }

    nonisolated static let defaultQuickActions: [MatchEventType] = [
        .goal, .shotOnTarget, .shotOffTarget, .keyPass, .tackleWon,
        .interception, .clearance, .save, .foulCommitted, .yellowCard, .substitution
    ]

    nonisolated var isShootoutAttempt: Bool {
        switch self {
        case .penaltyScored, .penaltyMissed, .penaltySaved:
            true
        default:
            false
        }
    }

    nonisolated static let configurableQuickActions: [MatchEventType] = allCases.filter {
        $0 != .assist && $0 != .foulWon && !$0.isShootoutAttempt
    }

    nonisolated static let watchPrimaryGroup: [MatchEventType] = [.goal, .shotOnTarget, .shotOffTarget, .foulCommitted, .tackleWon, .keyPass]
    nonisolated static let watchSecondaryGroup: [MatchEventType] = [.interception, .save, .yellowCard, .redCard, .cornerWon, .substitution]
    nonisolated static let watchMoreGroup: [MatchEventType] = configurableQuickActions.filter {
        !watchPrimaryGroup.contains($0) && !watchSecondaryGroup.contains($0)
    }

    nonisolated static func sanitizedTrackedEvents<S: Sequence>(from events: S) -> [MatchEventType] where S.Element == MatchEventType {
        let selectedEvents = Set(events)
        return configurableQuickActions.filter { selectedEvents.contains($0) }
    }

    nonisolated static func sanitizedTrackedEvents(fromRawValues rawValues: [String]) -> [MatchEventType] {
        let trackedEvents = sanitizedTrackedEvents(
            from: rawValues.compactMap { rawValue in
                MatchEventType(rawValue: MatchFormat.sanitizedRawValue(rawValue))
            }
        )
        if rawValues.isEmpty || !trackedEvents.isEmpty {
            return trackedEvents
        }
        return defaultQuickActions
    }
}
