import Foundation
import Observation

@MainActor
@Observable
final class WatchLiveState {
    var activeMatchID: UUID?
    var teamName = "Midline FC"
    var opponentName = "Opponent"
    var homeScore = 0
    var awayScore = 0
    var shootoutStatusRawValue = PenaltyShootoutStatus.notStarted.rawValue
    var homePenaltyScore = 0
    var awayPenaltyScore = 0
    var substitutionLimitModeRawValue = SubstitutionLimitMode.unlimited.rawValue
    var substitutionLimit = MatchFormat.defaultSubstitutionLimit
    var homeSubstitutionCount = 0
    var opponentSubstitutionCount = 0
    var currentHalf = 1
    var totalPeriods = MatchFormat.extraTimePeriodCount
    var extraTimeEnabled = false
    var extraTimeHalfDurationMinutes = MatchFormat.defaultExtraTimeHalfDurationMinutes
    var elapsedSeconds = 0
    var isLive = false
    var isFinished = false
    var trackedEventTypes = MatchEventType.defaultQuickActions
    var watchHapticsEnabled = true
    var watchHomeEventLoggingEnabled = true
    var watchOpponentEventLoggingEnabled = true
    var selectedTeamSide: TeamSide = .home
    var recentEvents: [WatchLoggedEvent] = []
    var deliveryState: WatchDeliveryState = .idle

    @discardableResult
    func apply(context: [String: Any]) -> Bool {
        if context["hasActiveMatch"] as? Bool == false {
            resetMatch()
            return true
        }

        guard
            let matchIDString = context["matchID"] as? String,
            let incomingMatchID = UUID(uuidString: MatchFormat.sanitizedRawValue(matchIDString))
        else {
            return false
        }

        if activeMatchID != incomingMatchID {
            resetActiveMatchState()
        }
        activeMatchID = incomingMatchID
        if let incomingTeamName = context["teamName"] as? String {
            teamName = sanitizedDisplayName(incomingTeamName, fallback: "Home")
        }
        if let incomingOpponentName = context["opponentName"] as? String {
            opponentName = sanitizedDisplayName(incomingOpponentName, fallback: "Opponent")
        }
        homeScore = (context["homeScore"] as? Int).map(MatchFormat.clampedScore) ?? homeScore
        awayScore = (context["awayScore"] as? Int).map(MatchFormat.clampedScore) ?? awayScore
        if let incomingShootoutStatus = context["shootoutStatus"] as? String {
            shootoutStatusRawValue = PenaltyShootoutStatus(rawValue: MatchFormat.sanitizedRawValue(incomingShootoutStatus))?.rawValue
                ?? PenaltyShootoutStatus.notStarted.rawValue
        }
        homePenaltyScore = (context["homePenaltyScore"] as? Int).map(MatchFormat.clampedScore) ?? homePenaltyScore
        awayPenaltyScore = (context["awayPenaltyScore"] as? Int).map(MatchFormat.clampedScore) ?? awayPenaltyScore
        if let incomingLimitMode = context["substitutionLimitMode"] as? String {
            substitutionLimitModeRawValue = SubstitutionLimitMode(rawValue: MatchFormat.sanitizedRawValue(incomingLimitMode))?.rawValue
                ?? SubstitutionLimitMode.unlimited.rawValue
        }
        substitutionLimit = (context["substitutionLimit"] as? Int).map(MatchFormat.clampedSubstitutionLimit) ?? substitutionLimit
        homeSubstitutionCount = (context["homeSubstitutionCount"] as? Int).map { max(0, $0) } ?? homeSubstitutionCount
        opponentSubstitutionCount = (context["opponentSubstitutionCount"] as? Int).map { max(0, $0) } ?? opponentSubstitutionCount
        if let incomingTotalPeriods = context["totalPeriods"] as? Int {
            totalPeriods = MatchFormat.clampedNumberOfPeriods(incomingTotalPeriods)
        }
        extraTimeEnabled = context["extraTimeEnabled"] as? Bool ?? extraTimeEnabled
        extraTimeHalfDurationMinutes = (context["extraTimeHalfDurationMinutes"] as? Int)
            .map(MatchFormat.clampedExtraTimeHalfDurationMinutes) ?? extraTimeHalfDurationMinutes
        currentHalf = (context["half"] as? Int).map {
            MatchFormat.clampedCurrentPeriod($0, numberOfPeriods: totalPeriods)
        } ?? currentHalf
        elapsedSeconds = (context["elapsedSeconds"] as? Int).map(MatchFormat.clampedElapsedSeconds) ?? elapsedSeconds
        isLive = context["isLive"] as? Bool ?? isLive
        isFinished = context["isFinished"] as? Bool ?? isFinished
        watchHapticsEnabled = context["watchHapticsEnabled"] as? Bool ?? watchHapticsEnabled
        watchHomeEventLoggingEnabled = context["watchHomeEventLoggingEnabled"] as? Bool ?? false
        watchOpponentEventLoggingEnabled = context["watchOpponentEventLoggingEnabled"] as? Bool ?? false
        if let rawValues = context["trackedEventTypes"] as? [String] {
            trackedEventTypes = MatchEventType.sanitizedTrackedEvents(fromRawValues: rawValues)
        } else {
            trackedEventTypes = []
        }
        if isFinished {
            isLive = false
            watchHomeEventLoggingEnabled = false
            watchOpponentEventLoggingEnabled = false
            deliveryState = .idle
        }
        normalizeSelectedTeamSideAvailability()

        return true
    }

    private func sanitizedDisplayName(_ value: String, fallback: String) -> String {
        MatchFormat.nameDisplayText(value, fallback: fallback)
    }

    func resetMatch() {
        activeMatchID = nil
        teamName = "No Match"
        opponentName = "Open iPhone"
        homeScore = 0
        awayScore = 0
        shootoutStatusRawValue = PenaltyShootoutStatus.notStarted.rawValue
        homePenaltyScore = 0
        awayPenaltyScore = 0
        substitutionLimitModeRawValue = SubstitutionLimitMode.unlimited.rawValue
        substitutionLimit = MatchFormat.defaultSubstitutionLimit
        homeSubstitutionCount = 0
        opponentSubstitutionCount = 0
        currentHalf = 1
        totalPeriods = MatchFormat.extraTimePeriodCount
        extraTimeEnabled = false
        extraTimeHalfDurationMinutes = MatchFormat.defaultExtraTimeHalfDurationMinutes
        elapsedSeconds = 0
        isLive = false
        isFinished = false
        trackedEventTypes = []
        watchHomeEventLoggingEnabled = false
        watchOpponentEventLoggingEnabled = false
        resetTransientMatchState()
    }

    private func resetTransientMatchState() {
        selectedTeamSide = .home
        recentEvents.removeAll()
        deliveryState = .idle
    }

    private func resetActiveMatchState() {
        teamName = "Home"
        opponentName = "Opponent"
        homeScore = 0
        awayScore = 0
        shootoutStatusRawValue = PenaltyShootoutStatus.notStarted.rawValue
        homePenaltyScore = 0
        awayPenaltyScore = 0
        substitutionLimitModeRawValue = SubstitutionLimitMode.unlimited.rawValue
        substitutionLimit = MatchFormat.defaultSubstitutionLimit
        homeSubstitutionCount = 0
        opponentSubstitutionCount = 0
        currentHalf = 1
        totalPeriods = MatchFormat.extraTimePeriodCount
        extraTimeEnabled = false
        extraTimeHalfDurationMinutes = MatchFormat.defaultExtraTimeHalfDurationMinutes
        elapsedSeconds = 0
        isLive = false
        isFinished = false
        trackedEventTypes = []
        watchHomeEventLoggingEnabled = false
        watchOpponentEventLoggingEnabled = false
        resetTransientMatchState()
    }

    func enabledEvents(from events: [MatchEventType]) -> [MatchEventType] {
        events.filter { trackedEventTypes.contains($0) }
    }

    func canSend(_ eventType: MatchEventType) -> Bool {
        activeMatchID != nil
        && !isFinished
        && !deliveryState.isSending
        && trackedEventTypes.contains(eventType)
        && canLogEventsForSelectedTeam
        && !isPenaltyShootoutActive
        && (eventType != .substitution || canUseSubstitution(for: selectedTeamSide))
    }

    var canLogEventsForSelectedTeam: Bool {
        selectedTeamSide == .home ? watchHomeEventLoggingEnabled : watchOpponentEventLoggingEnabled
    }

    var availableLoggingTeamSides: [TeamSide] {
        TeamSide.allCases.filter { teamSide in
            switch teamSide {
            case .home:
                watchHomeEventLoggingEnabled
            case .opponent:
                watchOpponentEventLoggingEnabled
            }
        }
    }

    private func normalizeSelectedTeamSideAvailability() {
        guard !canLogEventsForSelectedTeam else { return }
        if watchHomeEventLoggingEnabled {
            selectedTeamSide = .home
        } else if watchOpponentEventLoggingEnabled {
            selectedTeamSide = .opponent
        }
    }

    func push(_ eventType: MatchEventType, teamSide: TeamSide) {
        recentEvents.insert(.init(eventType: eventType, teamSide: teamSide), at: 0)
        recentEvents = Array(recentEvents.prefix(8))
    }

    func startSending(_ eventType: MatchEventType) {
        deliveryState = .sending(eventType.title)
    }

    @discardableResult
    func applyDeliveryResult(
        _ result: WatchEventDeliveryResult,
        eventType: MatchEventType,
        teamSide: TeamSide,
        matchID: UUID
    ) -> Bool {
        guard activeMatchID == matchID, !isFinished else { return false }

        switch result {
        case .accepted(let snapshot):
            if let homeScore = snapshot?.homeScore {
                self.homeScore = MatchFormat.clampedScore(homeScore)
            }
            if let awayScore = snapshot?.awayScore {
                self.awayScore = MatchFormat.clampedScore(awayScore)
            }
            if let elapsedSeconds = snapshot?.elapsedSeconds {
                self.elapsedSeconds = MatchFormat.clampedElapsedSeconds(elapsedSeconds)
            }
            push(eventType, teamSide: teamSide)
            deliveryState = .sent(eventType.title)
        case .rejected(let reason), .failed(let reason):
            deliveryState = .failed(deliveryFailureMessage(from: reason))
        }

        return true
    }

    private func deliveryFailureMessage(from reason: String) -> String {
        MatchFormat.singleLineDisplayText(reason, fallback: "Event could not be sent.")
    }

    func name(for teamSide: TeamSide) -> String {
        teamSide == .home ? teamName : opponentName
    }

    var shootoutStatus: PenaltyShootoutStatus {
        PenaltyShootoutStatus(rawValue: MatchFormat.sanitizedRawValue(shootoutStatusRawValue)) ?? .notStarted
    }

    var isPenaltyShootoutActive: Bool {
        shootoutStatus == .inProgress
    }

    var substitutionsAreUnlimited: Bool {
        SubstitutionLimitMode(rawValue: MatchFormat.sanitizedRawValue(substitutionLimitModeRawValue)) != .limited
    }

    var substitutionLimitValue: Int {
        MatchFormat.clampedSubstitutionLimit(substitutionLimit)
    }

    func substitutionCount(for teamSide: TeamSide) -> Int {
        teamSide == .home ? maxZero(homeSubstitutionCount) : maxZero(opponentSubstitutionCount)
    }

    func remainingSubstitutions(for teamSide: TeamSide) -> Int? {
        guard !substitutionsAreUnlimited else { return nil }
        return max(0, substitutionLimitValue - substitutionCount(for: teamSide))
    }

    func canUseSubstitution(for teamSide: TeamSide) -> Bool {
        remainingSubstitutions(for: teamSide).map { $0 > 0 } ?? true
    }

    var scoreLine: String {
        let suffix = shootoutStatus == .notStarted && homePenaltyScoreValue == 0 && awayPenaltyScoreValue == 0
            ? ""
            : " (\(homePenaltyScoreValue)-\(awayPenaltyScoreValue) pens)"
        return "\(teamName) \(homeScoreValue)-\(awayScoreValue) \(opponentName)\(suffix)"
    }

    var currentHalfTitle: String {
        if isPenaltyShootoutActive {
            return "Penalty Kicks"
        }
        return MatchFormat.title(forPeriod: MatchFormat.clampedCurrentPeriod(currentHalf, numberOfPeriods: totalPeriods))
    }

    var currentHalfShortTitle: String {
        if isPenaltyShootoutActive {
            return "P"
        }
        return MatchFormat.shortTitle(forPeriod: MatchFormat.clampedCurrentPeriod(currentHalf, numberOfPeriods: totalPeriods))
    }

    var clockText: String {
        MatchFormat.clockText(forElapsedSeconds: elapsedSeconds)
    }

    var homeScoreValue: Int {
        MatchFormat.clampedScore(homeScore)
    }

    var awayScoreValue: Int {
        MatchFormat.clampedScore(awayScore)
    }

    var homePenaltyScoreValue: Int {
        MatchFormat.clampedScore(homePenaltyScore)
    }

    var awayPenaltyScoreValue: Int {
        MatchFormat.clampedScore(awayPenaltyScore)
    }

    private func maxZero(_ value: Int) -> Int {
        max(0, value)
    }
}

enum WatchDeliveryState: Equatable {
    case idle
    case sending(String)
    case sent(String)
    case failed(String)

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle:
            nil
        case .sending(let eventTitle):
            "Sending \(eventTitle)..."
        case .sent(let eventTitle):
            "Sent \(eventTitle)"
        case .failed(let reason):
            reason
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct WatchLoggedEvent: Identifiable, Hashable {
    let id = UUID()
    let eventType: MatchEventType
    let teamSide: TeamSide
}
