import Foundation
import SwiftData

nonisolated enum MatchFormat {
    static let periodRange = 1...4
    static let durationRange = 1...130
    static let extraTimeHalfDurationRange = 1...45
    static let defaultExtraTimeHalfDurationMinutes = 15
    static let regulationPeriodCount = 2
    static let extraTimePeriodCount = 4
    static let substitutionLimitRange = 1...12
    static let defaultSubstitutionLimit = 5
    static let jerseyNumberRange = 0...999

    static func clampedNumberOfPeriods(_ value: Int) -> Int {
        min(max(value, periodRange.lowerBound), periodRange.upperBound)
    }

    static func clampedDurationMinutes(_ value: Int) -> Int {
        min(max(value, durationRange.lowerBound), durationRange.upperBound)
    }

    static func clampedExtraTimeHalfDurationMinutes(_ value: Int) -> Int {
        min(max(value, extraTimeHalfDurationRange.lowerBound), extraTimeHalfDurationRange.upperBound)
    }

    static func clampedSubstitutionLimit(_ value: Int) -> Int {
        min(max(value, substitutionLimitRange.lowerBound), substitutionLimitRange.upperBound)
    }

    static func clampedCurrentPeriod(_ value: Int, numberOfPeriods: Int) -> Int {
        min(max(value, periodRange.lowerBound), clampedNumberOfPeriods(numberOfPeriods))
    }

    static func clampedElapsedSeconds(_ value: Int) -> Int {
        max(0, value)
    }

    static func clampedMatchMinute(_ value: Int) -> Int {
        max(1, value)
    }

    static func clampedScore(_ value: Int) -> Int {
        max(0, value)
    }

    static func sanitizedJerseyNumber(_ value: Int?) -> Int? {
        guard let value, jerseyNumberRange.contains(value) else { return nil }
        return value
    }

    static func sanitizedJerseyNumberText(_ value: String) -> String {
        value
            .compactMap { decimalDigitValue(for: $0) }
            .prefix(3)
            .map(String.init)
            .joined()
    }

    static func isJerseyNumberText(_ value: String) -> Bool {
        value.allSatisfy { decimalDigitValue(for: $0) != nil }
    }

    static func jerseyNumber(fromText value: String) -> Int? {
        let jerseyText = sanitizedJerseyNumberText(value)
        return sanitizedJerseyNumber(Int(jerseyText))
    }

    private static func decimalDigitValue(for character: Character) -> Int? {
        guard let value = character.wholeNumberValue, 0...9 ~= value else { return nil }
        return value
    }

    static func sanitizedDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    static func displayText(_ text: String?, fallback: String) -> String {
        sanitizedDisplayText(text) ?? fallback
    }

    static func sanitizedSingleLineText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return trimmedText.isEmpty ? nil : trimmedText
    }

    static func singleLineDisplayText(_ text: String?, fallback: String) -> String {
        sanitizedSingleLineText(text) ?? fallback
    }

    static func sanitizedNameText(_ text: String?) -> String? {
        guard let text = sanitizedSingleLineText(text), containsNameText(text) else { return nil }
        return text
    }

    static func nameDisplayText(_ text: String?, fallback: String) -> String {
        sanitizedNameText(text) ?? fallback
    }

    static func containsNameText(_ value: String) -> Bool {
        value.contains { $0.isLetter || $0.isNumber }
    }

    static func sanitizedRawValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clockText(forElapsedSeconds elapsedSeconds: Int) -> String {
        let safeElapsedSeconds = clampedElapsedSeconds(elapsedSeconds)
        let minutes = safeElapsedSeconds / 60
        let seconds = safeElapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func eventClockText(forElapsedSeconds elapsedSeconds: Int) -> String {
        let safeElapsedSeconds = clampedElapsedSeconds(elapsedSeconds)
        let minutes = safeElapsedSeconds / 60
        let seconds = safeElapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func title(forPeriod period: Int) -> String {
        switch period {
        case ...1:
            "1st Half"
        case 2:
            "2nd Half"
        default:
            "Extra Time \(period - 2)"
        }
    }

    static func shortTitle(forPeriod period: Int) -> String {
        switch period {
        case ...1:
            "H1"
        case 2:
            "H2"
        default:
            "ET\(period - 2)"
        }
    }
}

enum PenaltyShootoutStatus: String, Codable, CaseIterable, Identifiable {
    case notStarted
    case inProgress
    case finished

    var id: String { rawValue }
}

enum SubstitutionLimitMode: String, Codable, CaseIterable, Identifiable {
    case unlimited
    case limited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimited: "Unlimited / Rolling"
        case .limited: "Limited"
        }
    }
}

@Model
final class MatchRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var teamName: String
    var opponentName: String
    var date: Date
    var durationMinutes: Int
    var numberOfHalves: Int
    var extraTimeEnabled: Bool?
    var extraTimeHalfDurationMinutes: Int?
    var shootoutStatusRawValue: String?
    var homePenaltyScore: Int?
    var awayPenaltyScore: Int?
    var substitutionLimitModeRawValue: String?
    var substitutionLimit: Int?
    var isQuickMatch: Bool
    var currentHalf: Int
    var homeScore: Int
    var awayScore: Int
    var elapsedSeconds: Int
    var isLive: Bool
    var isFinished: Bool
    var accentRawValue: String
    var trackedEventTypeRawValues: [String]?
    @Relationship(deleteRule: .cascade, inverse: \PlayerRecord.match) var players: [PlayerRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \MatchEventRecord.match) var events: [MatchEventRecord] = []

    init(
        id: UUID = UUID(),
        title: String,
        teamName: String,
        opponentName: String,
        date: Date = .now,
        durationMinutes: Int = 90,
        numberOfHalves: Int = 2,
        extraTimeEnabled: Bool = false,
        extraTimeHalfDurationMinutes: Int = MatchFormat.defaultExtraTimeHalfDurationMinutes,
        shootoutStatus: PenaltyShootoutStatus = .notStarted,
        homePenaltyScore: Int = 0,
        awayPenaltyScore: Int = 0,
        substitutionLimitMode: SubstitutionLimitMode = .unlimited,
        substitutionLimit: Int = MatchFormat.defaultSubstitutionLimit,
        isQuickMatch: Bool = false,
        currentHalf: Int = 1,
        homeScore: Int = 0,
        awayScore: Int = 0,
        elapsedSeconds: Int = 0,
        isLive: Bool = true,
        isFinished: Bool = false,
        accent: AppThemeAccent = .stadiumGreen,
        trackedEventTypes: [MatchEventType] = MatchEventType.defaultQuickActions
    ) {
        let clampedNumberOfHalves = MatchFormat.clampedNumberOfPeriods(numberOfHalves)
        let shouldEnableExtraTime = extraTimeEnabled || clampedNumberOfHalves > MatchFormat.regulationPeriodCount
        let totalPeriods = shouldEnableExtraTime ? MatchFormat.extraTimePeriodCount : clampedNumberOfHalves
        let cleanTeamName = MatchFormat.nameDisplayText(teamName, fallback: "Home")
        let cleanOpponentName = MatchFormat.nameDisplayText(opponentName, fallback: "Opponent")
        self.id = id
        self.title = MatchFormat.sanitizedNameText(title) ?? "\(cleanTeamName) vs \(cleanOpponentName)"
        self.teamName = cleanTeamName
        self.opponentName = cleanOpponentName
        self.date = date
        self.durationMinutes = MatchFormat.clampedDurationMinutes(durationMinutes)
        self.numberOfHalves = totalPeriods
        self.extraTimeEnabled = shouldEnableExtraTime
        self.extraTimeHalfDurationMinutes = MatchFormat.clampedExtraTimeHalfDurationMinutes(extraTimeHalfDurationMinutes)
        self.shootoutStatusRawValue = shootoutStatus.rawValue
        self.homePenaltyScore = MatchFormat.clampedScore(homePenaltyScore)
        self.awayPenaltyScore = MatchFormat.clampedScore(awayPenaltyScore)
        self.substitutionLimitModeRawValue = substitutionLimitMode.rawValue
        self.substitutionLimit = MatchFormat.clampedSubstitutionLimit(substitutionLimit)
        self.isQuickMatch = isQuickMatch
        self.currentHalf = MatchFormat.clampedCurrentPeriod(currentHalf, numberOfPeriods: totalPeriods)
        self.homeScore = MatchFormat.clampedScore(homeScore)
        self.awayScore = MatchFormat.clampedScore(awayScore)
        self.elapsedSeconds = MatchFormat.clampedElapsedSeconds(elapsedSeconds)
        self.isLive = isLive && !isFinished
        self.isFinished = isFinished
        self.accentRawValue = accent.rawValue
        self.trackedEventTypeRawValues = Self.rawTrackedEventValues(from: trackedEventTypes)
    }

    var accent: AppThemeAccent {
        get { AppThemeAccent(rawValue: MatchFormat.sanitizedRawValue(accentRawValue)) ?? .stadiumGreen }
        set { accentRawValue = newValue.rawValue }
    }

    var trackedEventTypes: [MatchEventType] {
        get {
            guard let trackedEventTypeRawValues else {
                return MatchEventType.defaultQuickActions
            }
            return Self.trackedEventTypes(fromRawValues: trackedEventTypeRawValues)
        }
        set { trackedEventTypeRawValues = Self.rawTrackedEventValues(from: newValue) }
    }

    var shootoutStatus: PenaltyShootoutStatus {
        get {
            guard let shootoutStatusRawValue else { return .notStarted }
            return PenaltyShootoutStatus(rawValue: MatchFormat.sanitizedRawValue(shootoutStatusRawValue)) ?? .notStarted
        }
        set { shootoutStatusRawValue = newValue.rawValue }
    }

    var substitutionLimitMode: SubstitutionLimitMode {
        get {
            guard let substitutionLimitModeRawValue else { return .unlimited }
            return SubstitutionLimitMode(rawValue: MatchFormat.sanitizedRawValue(substitutionLimitModeRawValue)) ?? .unlimited
        }
        set { substitutionLimitModeRawValue = newValue.rawValue }
    }

    var displayTitle: String {
        MatchFormat.sanitizedNameText(title) ?? "\(displayTeamName) vs \(displayOpponentName)"
    }

    var displayTeamName: String {
        MatchFormat.nameDisplayText(teamName, fallback: "Home")
    }

    var displayOpponentName: String {
        MatchFormat.nameDisplayText(opponentName, fallback: "Opponent")
    }

    var currentHalfTitle: String {
        MatchFormat.title(forPeriod: currentPeriodNumber)
    }

    var currentHalfShortTitle: String {
        MatchFormat.shortTitle(forPeriod: currentPeriodNumber)
    }

    var displayScoreLine: String {
        "\(displayTeamName) \(homeScoreValue) - \(awayScoreValue) \(displayOpponentName)\(shootoutScoreSuffix)"
    }

    var compactScoreLine: String {
        "\(displayTeamName) \(homeScoreValue)-\(awayScoreValue) \(displayOpponentName)\(shootoutScoreSuffix)"
    }

    private var shootoutScoreSuffix: String {
        hasPenaltyShootout ? " (\(homePenaltyScoreValue)-\(awayPenaltyScoreValue) pens)" : ""
    }

    var totalPeriodNumber: Int {
        usesExtraTime ? MatchFormat.extraTimePeriodCount : min(
            MatchFormat.clampedNumberOfPeriods(numberOfHalves),
            MatchFormat.regulationPeriodCount
        )
    }

    var durationMinuteValue: Int {
        MatchFormat.clampedDurationMinutes(durationMinutes)
    }

    var extraTimeHalfDurationMinuteValue: Int {
        MatchFormat.clampedExtraTimeHalfDurationMinutes(
            extraTimeHalfDurationMinutes ?? MatchFormat.defaultExtraTimeHalfDurationMinutes
        )
    }

    var substitutionLimitValue: Int {
        MatchFormat.clampedSubstitutionLimit(substitutionLimit ?? MatchFormat.defaultSubstitutionLimit)
    }

    var substitutionsAreUnlimited: Bool {
        substitutionLimitMode == .unlimited
    }

    var substitutionLimitSummaryText: String {
        substitutionsAreUnlimited ? "Unlimited substitutions" : "\(substitutionLimitValue) substitutions"
    }

    var usesExtraTime: Bool {
        (extraTimeEnabled ?? false) || MatchFormat.clampedNumberOfPeriods(numberOfHalves) > MatchFormat.regulationPeriodCount
    }

    var canStartExtraTimeFromRegulation: Bool {
        !isFinished && !usesExtraTime && currentPeriodNumber >= MatchFormat.regulationPeriodCount
    }

    var isPenaltyShootoutActive: Bool {
        shootoutStatus == .inProgress
    }

    var hasPenaltyShootout: Bool {
        shootoutStatus != .notStarted
        || homePenaltyScoreValue > 0
        || awayPenaltyScoreValue > 0
        || events.contains { $0.validEventType?.isShootoutAttempt == true }
    }

    var canStartPenaltyShootout: Bool {
        !isFinished && !isPenaltyShootoutActive && homeScoreValue == awayScoreValue
    }

    var formatSummaryText: String {
        if usesExtraTime {
            return "\(durationMinuteValue) min + ET \(extraTimeHalfDurationMinuteValue) min halves"
        }
        return "\(durationMinuteValue) min regulation"
    }

    var currentPeriodNumber: Int {
        MatchFormat.clampedCurrentPeriod(currentHalf, numberOfPeriods: totalPeriodNumber)
    }

    var elapsedClockSeconds: Int {
        MatchFormat.clampedElapsedSeconds(elapsedSeconds)
    }

    var homeScoreValue: Int {
        MatchFormat.clampedScore(homeScore)
    }

    var awayScoreValue: Int {
        MatchFormat.clampedScore(awayScore)
    }

    var homePenaltyScoreValue: Int {
        MatchFormat.clampedScore(homePenaltyScore ?? 0)
    }

    var awayPenaltyScoreValue: Int {
        MatchFormat.clampedScore(awayPenaltyScore ?? 0)
    }

    func normalizePersistedValues() {
        durationMinutes = durationMinuteValue
        extraTimeEnabled = usesExtraTime
        numberOfHalves = totalPeriodNumber
        extraTimeHalfDurationMinutes = extraTimeHalfDurationMinuteValue
        shootoutStatusRawValue = shootoutStatus.rawValue
        homePenaltyScore = homePenaltyScoreValue
        awayPenaltyScore = awayPenaltyScoreValue
        substitutionLimitModeRawValue = substitutionLimitMode.rawValue
        substitutionLimit = substitutionLimitValue
        currentHalf = currentPeriodNumber
        homeScore = homeScoreValue
        awayScore = awayScoreValue
        elapsedSeconds = elapsedClockSeconds
        isLive = isLive && !isFinished
        accentRawValue = accent.rawValue
        trackedEventTypes = trackedEventTypes
    }

    private static func rawTrackedEventValues(from eventTypes: [MatchEventType]) -> [String] {
        MatchEventType.sanitizedTrackedEvents(from: eventTypes).map(\.rawValue)
    }

    private static func trackedEventTypes(fromRawValues rawValues: [String]) -> [MatchEventType] {
        MatchEventType.sanitizedTrackedEvents(fromRawValues: rawValues)
    }

    func matchesSearchQuery(_ query: String) -> Bool {
        guard
            let searchQuery = MatchFormat.sanitizedSingleLineText(query),
            MatchFormat.containsNameText(searchQuery)
        else {
            return true
        }

        return searchFields.contains {
            $0.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var searchFields: [String] {
        [
            displayTitle,
            displayTeamName,
            displayOpponentName,
            date.formatted(date: .abbreviated, time: .omitted),
            date.formatted(date: .numeric, time: .omitted)
        ]
    }

    func player(id playerID: UUID, teamSide: TeamSide) -> PlayerRecord? {
        players.first { player in
            player.id == playerID && player.validTeamSide == teamSide
        }
    }

    func player(for event: MatchEventRecord) -> PlayerRecord? {
        guard let playerID = event.playerID, let teamSide = event.validTeamSide else { return nil }
        return player(id: playerID, teamSide: teamSide)
    }

    func secondaryPlayer(for event: MatchEventRecord) -> PlayerRecord? {
        guard let playerID = event.secondaryPlayerID, let teamSide = event.validTeamSide else { return nil }
        return player(id: playerID, teamSide: teamSide)
    }

    func timelineDetailText(for event: MatchEventRecord) -> String? {
        guard event.hasValidRawValues else { return nil }

        let primaryPlayerName = player(for: event)?.displayName
        let secondaryPlayerName = secondaryPlayer(for: event)?.displayName
        let playerText: String?

        if event.validEventType == .substitution, let primaryPlayerName, let secondaryPlayerName {
            playerText = "\(primaryPlayerName) -> \(secondaryPlayerName)"
        } else {
            playerText = primaryPlayerName
        }

        if let playerText, let notes = event.notesText {
            return "\(playerText) • \(notes)"
        }
        if let playerText {
            return playerText
        }
        return event.notesText ?? event.validSourceDevice?.displayTitle
    }

    func summaryTimelineDetailText(for event: MatchEventRecord, scope: MatchAnalyticsScope) -> String? {
        let detailText = timelineDetailText(for: event)
        guard scope == .both, let teamSide = event.validTeamSide else {
            return detailText
        }

        let teamText = displayName(for: teamSide)
        if let detailText {
            return "\(teamText) • \(detailText)"
        }
        return teamText
    }

    func summaryTimelineEvents(for scope: MatchAnalyticsScope) -> [MatchEventRecord] {
        events
            .filter { event in
                guard event.hasValidRawValues, let teamSide = event.validTeamSide else { return false }
                return scope.includes(teamSide)
            }
            .sortedForTimeline()
    }

    func displayName(for teamSide: TeamSide) -> String {
        teamSide == .home ? displayTeamName : displayOpponentName
    }

    func substitutionCount(for teamSide: TeamSide) -> Int {
        events.filter {
            $0.hasValidRawValues
            && $0.validEventType == .substitution
            && $0.validTeamSide == teamSide
        }.count
    }

    func remainingSubstitutions(for teamSide: TeamSide) -> Int? {
        guard !substitutionsAreUnlimited else { return nil }
        return max(0, substitutionLimitValue - substitutionCount(for: teamSide))
    }

    func canUseSubstitution(for teamSide: TeamSide) -> Bool {
        remainingSubstitutions(for: teamSide).map { $0 > 0 } ?? true
    }

    func liveActivePlayerIDs(for teamSide: TeamSide) -> Set<UUID> {
        let sidePlayers = players.filter { $0.validTeamSide == teamSide }
        let sidePlayerIDs = Set(sidePlayers.map(\.id))
        var activeIDs = Set(sidePlayers.filter(\.isStarter).map(\.id))

        let substitutions = events
            .filter { $0.validPeriod != nil && $0.validTeamSide == teamSide && $0.validEventType == .substitution }
            .sortedForTimeline()

        for event in substitutions {
            guard
                let playerOffID = event.playerID,
                let playerOnID = event.secondaryPlayerID,
                playerOffID != playerOnID,
                sidePlayerIDs.contains(playerOffID),
                activeIDs.contains(playerOffID),
                sidePlayerIDs.contains(playerOnID),
                !activeIDs.contains(playerOnID)
            else {
                continue
            }

            activeIDs.remove(playerOffID)
            activeIDs.insert(playerOnID)
        }

        return activeIDs
    }
}

extension Sequence where Element == MatchRecord {
    func preferredActiveMatch(currentActiveMatch: MatchRecord?) -> MatchRecord? {
        let unfinishedMatches = filter { !$0.isFinished }
        if let currentActiveMatch,
           let matchingActive = unfinishedMatches.first(where: { $0.id == currentActiveMatch.id }) {
            return matchingActive
        }

        return unfinishedMatches.max { lhs, rhs in
            if lhs.isLive != rhs.isLive {
                return !lhs.isLive && rhs.isLive
            }
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

@Model
final class PlayerRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var jerseyNumber: Int?
    var positionRawValue: String
    var isFavorite: Bool
    var isPinned: Bool
    var isStarter: Bool
    var teamSideRawValue: String
    var match: MatchRecord?

    init(
        id: UUID = UUID(),
        name: String,
        jerseyNumber: Int? = nil,
        position: PlayerPosition = .utility,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        isStarter: Bool = true,
        teamSide: TeamSide = .home,
        match: MatchRecord? = nil
    ) {
        self.id = id
        self.name = MatchFormat.nameDisplayText(name, fallback: "Unknown Player")
        self.jerseyNumber = MatchFormat.sanitizedJerseyNumber(jerseyNumber)
        self.positionRawValue = position.rawValue
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.isStarter = isStarter
        self.teamSideRawValue = teamSide.rawValue
        self.match = match
    }

    var position: PlayerPosition {
        get { PlayerPosition(rawValue: MatchFormat.sanitizedRawValue(positionRawValue)) ?? .utility }
        set { positionRawValue = newValue.rawValue }
    }

    var teamSide: TeamSide {
        get { TeamSide(rawValue: MatchFormat.sanitizedRawValue(teamSideRawValue)) ?? .home }
        set { teamSideRawValue = newValue.rawValue }
    }

    var validTeamSide: TeamSide? {
        TeamSide(rawValue: MatchFormat.sanitizedRawValue(teamSideRawValue))
    }

    var jerseyNumberValue: Int? {
        MatchFormat.sanitizedJerseyNumber(jerseyNumber)
    }

    var displayName: String {
        MatchFormat.nameDisplayText(name, fallback: "Unknown Player")
    }
}

extension Sequence where Element == PlayerRecord {
    func sortedForPlayerSelection() -> [PlayerRecord] {
        sorted { lhs, rhs in
            switch (lhs.jerseyNumberValue, rhs.jerseyNumberValue) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                if lhs.position != rhs.position {
                    return lhs.position.rawValue < rhs.position.rawValue
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}

enum TeamSide: String, Codable, CaseIterable, Identifiable {
    case home
    case opponent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Us"
        case .opponent: "Them"
        }
    }
}

enum MatchAnalyticsScope: String, CaseIterable, Identifiable {
    case home
    case opponent
    case both

    var id: String { rawValue }

    var segmentedTitle: String {
        switch self {
        case .home:
            "Us"
        case .opponent:
            "Them"
        case .both:
            "Both"
        }
    }

    func title(for match: MatchRecord) -> String {
        switch self {
        case .home:
            match.displayTeamName
        case .opponent:
            match.displayOpponentName
        case .both:
            "Both Teams"
        }
    }

    func includes(_ teamSide: TeamSide) -> Bool {
        switch self {
        case .home:
            teamSide == .home
        case .opponent:
            teamSide == .opponent
        case .both:
            true
        }
    }
}

@Model
final class MatchEventRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var matchMinute: Int
    var elapsedSeconds: Int?
    var periodRawValue: String
    var eventTypeRawValue: String
    var teamSideRawValue: String
    var playerID: UUID?
    var secondaryPlayerID: UUID?
    var linkedGroupID: UUID?
    var notes: String?
    var pitchX: Double?
    var pitchY: Double?
    var sourceDeviceRawValue: String?
    var match: MatchRecord?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        matchMinute: Int,
        elapsedSeconds: Int? = nil,
        period: MatchPeriod,
        eventType: MatchEventType,
        teamSide: TeamSide = .home,
        playerID: UUID? = nil,
        secondaryPlayerID: UUID? = nil,
        linkedGroupID: UUID? = nil,
        notes: String? = nil,
        pitchX: Double? = nil,
        pitchY: Double? = nil,
        sourceDevice: SourceDevice = .iPhone,
        match: MatchRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.matchMinute = MatchFormat.clampedMatchMinute(matchMinute)
        self.elapsedSeconds = elapsedSeconds.map(MatchFormat.clampedElapsedSeconds)
        self.periodRawValue = period.rawValue
        self.eventTypeRawValue = eventType.rawValue
        self.teamSideRawValue = teamSide.rawValue
        self.playerID = playerID
        self.secondaryPlayerID = secondaryPlayerID
        self.linkedGroupID = linkedGroupID
        self.notes = MatchFormat.sanitizedDisplayText(notes)
        self.pitchX = pitchX
        self.pitchY = pitchY
        self.sourceDeviceRawValue = sourceDevice.rawValue
        self.match = match
    }

    var period: MatchPeriod {
        get { MatchPeriod(rawValue: MatchFormat.sanitizedRawValue(periodRawValue)) ?? .firstHalf }
        set { periodRawValue = newValue.rawValue }
    }

    var validPeriod: MatchPeriod? {
        MatchPeriod(rawValue: MatchFormat.sanitizedRawValue(periodRawValue))
    }

    var eventType: MatchEventType {
        get { MatchEventType(rawValue: MatchFormat.sanitizedRawValue(eventTypeRawValue)) ?? .goal }
        set { eventTypeRawValue = newValue.rawValue }
    }

    var validEventType: MatchEventType? {
        MatchEventType(rawValue: MatchFormat.sanitizedRawValue(eventTypeRawValue))
    }

    var teamSide: TeamSide {
        get { TeamSide(rawValue: MatchFormat.sanitizedRawValue(teamSideRawValue)) ?? .home }
        set { teamSideRawValue = newValue.rawValue }
    }

    var validTeamSide: TeamSide? {
        TeamSide(rawValue: MatchFormat.sanitizedRawValue(teamSideRawValue))
    }

    var hasValidRawValues: Bool {
        validPeriod != nil && validEventType != nil && validTeamSide != nil
    }

    var sourceDevice: SourceDevice {
        get {
            guard let sourceDeviceRawValue else { return .iPhone }
            return SourceDevice(rawValue: MatchFormat.sanitizedRawValue(sourceDeviceRawValue)) ?? .iPhone
        }
        set { sourceDeviceRawValue = newValue.rawValue }
    }

    var validSourceDevice: SourceDevice? {
        guard let sourceDeviceRawValue else { return nil }
        return SourceDevice(rawValue: MatchFormat.sanitizedRawValue(sourceDeviceRawValue))
    }

    var matchMinuteValue: Int {
        MatchFormat.clampedMatchMinute(matchMinute)
    }

    var matchClockText: String {
        if let elapsedSeconds {
            return MatchFormat.eventClockText(forElapsedSeconds: elapsedSeconds)
        }
        return MatchFormat.eventClockText(forElapsedSeconds: matchMinuteValue * 60)
    }

    var notesText: String? {
        MatchFormat.sanitizedDisplayText(notes)
    }

    var displayTitle: String {
        validEventType?.title ?? "Unknown Event"
    }

    func normalizePersistedValues() {
        elapsedSeconds = elapsedSeconds.map(MatchFormat.clampedElapsedSeconds)
        sourceDeviceRawValue = sourceDevice.rawValue
    }
}

extension Sequence where Element == MatchEventRecord {
    func linkedEventGroup(containing event: MatchEventRecord) -> [MatchEventRecord] {
        guard event.hasValidRawValues else {
            return filter { $0.id == event.id }
        }

        if let linkedGroupID = event.linkedGroupID {
            return filter { candidate in
                guard candidate.linkedGroupID == linkedGroupID, candidate.hasValidRawValues else {
                    return false
                }

                return candidate.id == event.id || candidate.isLinked(to: event)
            }
        }

        let linkedCandidates = filter { candidate in
            candidate.id != event.id && candidate.linkedGroupID == nil && candidate.isLinked(to: event)
        }
        guard linkedCandidates.count == 1 else {
            return filter { $0.id == event.id }
        }

        let linkedIDs = Set([event.id, linkedCandidates[0].id])
        return filter { linkedIDs.contains($0.id) }
    }

    func sortedForTimeline() -> [MatchEventRecord] {
        sorted { lhs, rhs in
            if lhs.matchMinuteValue != rhs.matchMinuteValue {
                return lhs.matchMinuteValue < rhs.matchMinuteValue
            }

            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }

            if lhs.timelineSortPriority != rhs.timelineSortPriority {
                return lhs.timelineSortPriority < rhs.timelineSortPriority
            }

            let titleOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func sortedForRecentTimeline() -> [MatchEventRecord] {
        sorted { lhs, rhs in
            if lhs.matchMinuteValue != rhs.matchMinuteValue {
                return lhs.matchMinuteValue > rhs.matchMinuteValue
            }

            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }

            if lhs.timelineSortPriority != rhs.timelineSortPriority {
                return lhs.timelineSortPriority < rhs.timelineSortPriority
            }

            let titleOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

private extension MatchEventRecord {
    func isLinked(to event: MatchEventRecord) -> Bool {
        guard timestamp == event.timestamp, hasValidRawValues, event.hasValidRawValues else { return false }

        if isAssistLinked(to: event) || event.isAssistLinked(to: self) {
            return true
        }

        if isFoulPairLinked(to: event) || event.isFoulPairLinked(to: self) {
            return true
        }

        return isSecondYellowRedLinked(to: event) || event.isSecondYellowRedLinked(to: self)
    }

    func isAssistLinked(to event: MatchEventRecord) -> Bool {
        guard
            validEventType == .assist,
            event.validEventType == .goal,
            validTeamSide == event.validTeamSide,
            let playerID,
            let eventSecondaryPlayerID = event.secondaryPlayerID
        else {
            return false
        }

        return playerID == eventSecondaryPlayerID
    }

    func isFoulPairLinked(to event: MatchEventRecord) -> Bool {
        guard
            validEventType == .foulWon,
            event.validEventType == .foulCommitted,
            let teamSide = validTeamSide,
            let eventTeamSide = event.validTeamSide
        else {
            return false
        }

        return teamSide != eventTeamSide
    }

    func isSecondYellowRedLinked(to event: MatchEventRecord) -> Bool {
        guard
            validEventType == .redCard,
            event.validEventType == .yellowCard,
            validTeamSide == event.validTeamSide,
            let playerID,
            let eventPlayerID = event.playerID
        else {
            return false
        }

        return playerID == eventPlayerID
    }

    var timelineSortPriority: Int {
        switch validEventType {
        case .some(.goal), .some(.foulCommitted), .some(.yellowCard):
            0
        case .some(.assist), .some(.foulWon), .some(.redCard):
            1
        default:
            0
        }
    }
}

@Model
final class AppSettingsRecord {
    @Attribute(.unique) var id: UUID
    var defaultDurationMinutes: Int
    var defaultNumberOfHalves: Int
    var defaultExtraTimeEnabled: Bool?
    var defaultExtraTimeHalfDurationMinutes: Int?
    var defaultSubstitutionLimitModeRawValue: String?
    var defaultSubstitutionLimit: Int?
    var themeAccentRawValue: String
    var quickActionsData: Data

    init(
        id: UUID = UUID(),
        defaultDurationMinutes: Int = 90,
        defaultNumberOfHalves: Int = 2,
        defaultExtraTimeEnabled: Bool = false,
        defaultExtraTimeHalfDurationMinutes: Int = MatchFormat.defaultExtraTimeHalfDurationMinutes,
        defaultSubstitutionLimitMode: SubstitutionLimitMode = .unlimited,
        defaultSubstitutionLimit: Int = MatchFormat.defaultSubstitutionLimit,
        themeAccent: AppThemeAccent = .stadiumGreen,
        quickActions: QuickActionConfiguration = .init()
    ) {
        let clampedDefaultNumberOfHalves = MatchFormat.clampedNumberOfPeriods(defaultNumberOfHalves)
        self.id = id
        self.defaultDurationMinutes = MatchFormat.clampedDurationMinutes(defaultDurationMinutes)
        self.defaultNumberOfHalves = clampedDefaultNumberOfHalves
        self.defaultExtraTimeEnabled = defaultExtraTimeEnabled || clampedDefaultNumberOfHalves > MatchFormat.regulationPeriodCount
        self.defaultExtraTimeHalfDurationMinutes = MatchFormat.clampedExtraTimeHalfDurationMinutes(defaultExtraTimeHalfDurationMinutes)
        self.defaultSubstitutionLimitModeRawValue = defaultSubstitutionLimitMode.rawValue
        self.defaultSubstitutionLimit = MatchFormat.clampedSubstitutionLimit(defaultSubstitutionLimit)
        self.themeAccentRawValue = themeAccent.rawValue
        self.quickActionsData = (try? JSONEncoder().encode(quickActions)) ?? Data()
    }

    var themeAccent: AppThemeAccent {
        get { AppThemeAccent(rawValue: MatchFormat.sanitizedRawValue(themeAccentRawValue)) ?? .stadiumGreen }
        set { themeAccentRawValue = newValue.rawValue }
    }

    var defaultDurationMinuteValue: Int {
        MatchFormat.clampedDurationMinutes(defaultDurationMinutes)
    }

    var defaultNumberOfHalvesValue: Int {
        MatchFormat.clampedNumberOfPeriods(defaultNumberOfHalves)
    }

    var defaultUsesExtraTime: Bool {
        (defaultExtraTimeEnabled ?? false) || defaultNumberOfHalvesValue > MatchFormat.regulationPeriodCount
    }

    var defaultTotalPeriodNumber: Int {
        defaultUsesExtraTime ? MatchFormat.extraTimePeriodCount : min(
            defaultNumberOfHalvesValue,
            MatchFormat.regulationPeriodCount
        )
    }

    var defaultExtraTimeHalfDurationMinuteValue: Int {
        MatchFormat.clampedExtraTimeHalfDurationMinutes(
            defaultExtraTimeHalfDurationMinutes ?? MatchFormat.defaultExtraTimeHalfDurationMinutes
        )
    }

    var defaultSubstitutionLimitMode: SubstitutionLimitMode {
        get {
            guard let defaultSubstitutionLimitModeRawValue else { return .unlimited }
            return SubstitutionLimitMode(rawValue: MatchFormat.sanitizedRawValue(defaultSubstitutionLimitModeRawValue)) ?? .unlimited
        }
        set { defaultSubstitutionLimitModeRawValue = newValue.rawValue }
    }

    var defaultSubstitutionLimitValue: Int {
        MatchFormat.clampedSubstitutionLimit(defaultSubstitutionLimit ?? MatchFormat.defaultSubstitutionLimit)
    }

    var quickActions: QuickActionConfiguration {
        get { (try? JSONDecoder().decode(QuickActionConfiguration.self, from: quickActionsData)) ?? .init() }
        set { quickActionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    func normalizePersistedValues() {
        defaultDurationMinutes = defaultDurationMinuteValue
        defaultExtraTimeEnabled = defaultUsesExtraTime
        defaultNumberOfHalves = defaultTotalPeriodNumber
        defaultExtraTimeHalfDurationMinutes = defaultExtraTimeHalfDurationMinuteValue
        defaultSubstitutionLimitModeRawValue = defaultSubstitutionLimitMode.rawValue
        defaultSubstitutionLimit = defaultSubstitutionLimitValue
        themeAccentRawValue = themeAccent.rawValue
        quickActions = quickActions
    }
}

extension Sequence where Element == AppSettingsRecord {
    var preferredSettingsRecord: AppSettingsRecord? {
        self.min { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct EventDraft: Identifiable, Hashable {
    let id = UUID()
    let type: MatchEventType
    var teamSide: TeamSide = .home
    var primaryPlayerID: UUID?
    var secondaryPlayerID: UUID?
    var note = ""
    var tag = ""

    var withoutOptionalDetail: EventDraft {
        var draft = self
        draft.primaryPlayerID = nil
        draft.secondaryPlayerID = nil
        draft.note = ""
        draft.tag = ""
        return draft
    }
}

struct MatchSetupDraft: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var teamName: String
    var opponentName: String
    var date: Date = .now
    var durationMinutes: Int
    var numberOfHalves: Int
    var extraTimeEnabled = false
    var extraTimeHalfDurationMinutes = MatchFormat.defaultExtraTimeHalfDurationMinutes
    var substitutionLimitMode = SubstitutionLimitMode.unlimited
    var substitutionLimit = MatchFormat.defaultSubstitutionLimit
    var isQuickMatch: Bool
    var accent: AppThemeAccent
    var trackedEventTypes: [MatchEventType]
    var homeStartingPlayersText = ""
    var homeBenchPlayersText = ""
    var opponentStartingPlayersText = ""
    var opponentBenchPlayersText = ""

    var hasPlayers: Bool {
        [
            homeStartingPlayersText,
            homeBenchPlayersText,
            opponentStartingPlayersText,
            opponentBenchPlayersText
        ].contains(where: MatchSetupPlayerLineParser.containsPlayer)
    }

    static func duplicate(from match: MatchRecord, date: Date = .now) -> MatchSetupDraft {
        MatchSetupDraft(
            title: match.displayTitle,
            teamName: match.displayTeamName,
            opponentName: match.displayOpponentName,
            date: date,
            durationMinutes: match.durationMinuteValue,
            numberOfHalves: match.totalPeriodNumber,
            extraTimeEnabled: match.usesExtraTime,
            extraTimeHalfDurationMinutes: match.extraTimeHalfDurationMinuteValue,
            substitutionLimitMode: match.substitutionLimitMode,
            substitutionLimit: match.substitutionLimitValue,
            isQuickMatch: match.isQuickMatch,
            accent: match.accent,
            trackedEventTypes: match.trackedEventTypes,
            homeStartingPlayersText: playersText(from: match, teamSide: .home, isStarter: true),
            homeBenchPlayersText: playersText(from: match, teamSide: .home, isStarter: false),
            opponentStartingPlayersText: playersText(from: match, teamSide: .opponent, isStarter: true),
            opponentBenchPlayersText: playersText(from: match, teamSide: .opponent, isStarter: false)
        )
    }

    private static func playersText(from match: MatchRecord, teamSide: TeamSide, isStarter: Bool) -> String {
        match.players
            .filter { $0.validTeamSide == teamSide && $0.isStarter == isStarter }
            .sortedForPlayerSelection()
            .map { playerLine(for: $0) }
            .joined(separator: "\n")
    }

    private static func playerLine(for player: PlayerRecord) -> String {
        var parts = [lineFieldText(player.displayName)]
        parts.append(player.jerseyNumberValue.map { "#\($0)" } ?? "")
        parts.append(player.position.rawValue)

        return parts.joined(separator: ",")
    }

    private static func lineFieldText(_ text: String) -> String {
        let singleLineText = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard singleLineText.contains(",") || singleLineText.contains("\"") else {
            return singleLineText
        }

        return "\"\(singleLineText.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct MatchSetupPlayerLineDraft: Hashable {
    var name: String
    var jerseyNumberText: String
    var position: PlayerPosition
}

enum MatchSetupPlayerLineParser {
    nonisolated static func containsPlayer(in text: String) -> Bool {
        !parseLines(in: text).isEmpty
    }

    nonisolated static func parseLines(in text: String) -> [MatchSetupPlayerLineDraft] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { parse(String($0)) }
    }

    nonisolated static func parse(_ line: String) -> MatchSetupPlayerLineDraft? {
        guard !isHeaderLine(line) else { return nil }
        let components = parseComponents(from: line)
        guard let name = MatchFormat.sanitizedSingleLineText(components.name) else { return nil }
        guard containsNameText(name) else { return nil }

        return MatchSetupPlayerLineDraft(
            name: name,
            jerseyNumberText: components.jerseyNumberText,
            position: components.position
        )
    }

    private nonisolated static func parseComponents(from line: String) -> (name: String, jerseyNumberText: String, position: PlayerPosition) {
        var parts = parseFields(from: line)
        var position = PlayerPosition.utility
        var jerseyNumberText = ""
        removeTrailingEmptyFields(from: &parts)

        if parts.count > 1,
           let lastPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedPosition = PlayerPosition(rawValue: lastPart.lowercased()) {
            position = parsedPosition
            parts.removeLast()
        }

        if let lastPart = parts.last {
            let trimmedPart = lastPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if isJerseyField(trimmedPart) {
                jerseyNumberText = sanitizedJerseyText(from: trimmedPart)
                parts.removeLast()
            }
        }

        return (
            name: parts.joined(separator: ",").trimmingCharacters(in: .whitespacesAndNewlines),
            jerseyNumberText: jerseyNumberText,
            position: position
        )
    }

    private nonisolated static func parseFields(from line: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var isInsideQuotedField = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                if isInsideQuotedField {
                    let nextIndex = line.index(after: index)
                    if nextIndex < line.endIndex, line[nextIndex] == "\"" {
                        currentField.append("\"")
                        index = nextIndex
                    } else {
                        isInsideQuotedField = false
                    }
                } else if currentField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentField = ""
                    isInsideQuotedField = true
                } else {
                    currentField.append(character)
                }
            } else if character == ",", !isInsideQuotedField {
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(character)
            }

            index = line.index(after: index)
        }

        fields.append(currentField)
        return fields
    }

    private nonisolated static func isHeaderLine(_ line: String) -> Bool {
        var fields = parseFields(from: line).map {
            MatchFormat.sanitizedSingleLineText($0)?.lowercased() ?? ""
        }
        removeTrailingEmptyFields(from: &fields)
        guard fields.count > 1 else { return false }

        let nameHeaders = Set(["name", "player", "player name"])
        let detailHeaders = Set(["#", "number", "no", "jersey", "jersey number", "position", "pos"])

        return fields.contains { nameHeaders.contains($0) }
        && fields.contains { detailHeaders.contains($0) }
    }

    private nonisolated static func removeTrailingEmptyFields(from parts: inout [String]) {
        while parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            parts.removeLast()
        }
    }

    private nonisolated static func sanitizedJerseyText(from value: String) -> String {
        MatchFormat.sanitizedJerseyNumberText(value.replacingOccurrences(of: "#", with: ""))
    }

    private nonisolated static func isJerseyField(_ value: String) -> Bool {
        value.isEmpty || MatchFormat.isJerseyNumberText(value) || isHashJerseyField(value)
    }

    private nonisolated static func isHashJerseyField(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let numberText = value.dropFirst()
        return numberText.isEmpty || MatchFormat.isJerseyNumberText(String(numberText))
    }

    nonisolated static func containsNameText(_ value: String) -> Bool {
        MatchFormat.containsNameText(value)
    }
}

struct MatchStatLine: Identifiable, Hashable {
    let title: String
    let value: Int

    var id: String { title }
}

struct PlayerStatSummary: Identifiable, Hashable {
    let playerID: UUID
    let teamSide: TeamSide
    let playerName: String
    let stats: [MatchEventType: Int]

    var id: String {
        "\(teamSide.rawValue)-\(playerID.uuidString)"
    }
}

struct MatchAnalyticsSummary {
    let scoreLine: String
    let teamTotals: [MatchStatLine]
    let attackInvolvement: Int
    let defensiveInvolvement: Int
    let discipline: Int
    let ballRetentionImpact: Int
    let mostActivePlayer: PlayerStatSummary?
    let topAttackingContributor: PlayerStatSummary?
    let topDefensiveContributor: PlayerStatSummary?
}
