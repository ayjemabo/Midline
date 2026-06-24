import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MatchEngine {
    var activeMatch: MatchRecord?

    func select(match: MatchRecord) {
        activeMatch = match
    }

    func restore(match: MatchRecord) {
        select(match: match)
        normalizeMatchState(match)
    }

    @discardableResult
    func restorePreferredActiveMatch(afterDeletingIDs deletedMatchIDs: [UUID], from remainingMatches: [MatchRecord]) -> MatchRecord? {
        if let replacement = remainingMatches.preferredActiveMatch(currentActiveMatch: activeMatch) {
            restore(match: replacement)
            return replacement
        }

        for matchID in deletedMatchIDs {
            clearActiveMatch(ifMatchingID: matchID)
        }
        return nil
    }

    func restoreActiveMatchAfterFailedStart(
        failedMatchID: UUID,
        previousActiveMatch: MatchRecord?,
        previousActiveWasLive: Bool? = nil
    ) {
        guard clearActiveMatch(ifMatchingID: failedMatchID), let previousActiveMatch else { return }
        if let previousActiveWasLive {
            previousActiveMatch.isLive = previousActiveWasLive
        }
        restore(match: previousActiveMatch)
    }

    @discardableResult
    func clearActiveMatch(ifMatching match: MatchRecord) -> Bool {
        clearActiveMatch(ifMatchingID: match.id)
    }

    @discardableResult
    func clearActiveMatch(ifMatchingID matchID: UUID) -> Bool {
        guard activeMatch?.id == matchID else { return false }
        activeMatch = nil
        return true
    }

    @discardableResult
    func clearActiveMatchIfFinished(_ match: MatchRecord) -> Bool {
        guard match.isFinished else { return false }
        return clearActiveMatch(ifMatching: match)
    }

    func start(match: MatchRecord) {
        if activeMatch?.id != match.id {
            activeMatch?.isLive = false
        }
        select(match: match)
        normalizeMatchState(match)
        match.isLive = true
        match.isFinished = false
    }

    func tick() {
        guard let activeMatch, activeMatch.isLive, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        activeMatch.elapsedSeconds = activeMatch.elapsedClockSeconds + 1
    }

    func togglePause() {
        guard let activeMatch, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        activeMatch.isLive.toggle()
    }

    func advanceHalf() {
        guard let activeMatch, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        if activeMatch.currentHalf < activeMatch.totalPeriodNumber {
            activeMatch.currentHalf += 1
            activeMatch.isLive = true
        } else {
            endMatch()
        }
    }

    func startExtraTime() {
        guard let activeMatch, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        guard activeMatch.canStartExtraTimeFromRegulation else { return }
        activeMatch.extraTimeEnabled = true
        activeMatch.extraTimeHalfDurationMinutes = activeMatch.extraTimeHalfDurationMinuteValue
        activeMatch.numberOfHalves = MatchFormat.extraTimePeriodCount
        activeMatch.currentHalf = 3
        activeMatch.isLive = true
    }

    func startPenaltyShootout() {
        guard let activeMatch, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        guard activeMatch.canStartPenaltyShootout else { return }
        activeMatch.shootoutStatus = .inProgress
        activeMatch.isLive = true
    }

    func finishPenaltyShootout() {
        guard let activeMatch, !activeMatch.isFinished else { return }
        normalizeMatchState(activeMatch)
        guard activeMatch.isPenaltyShootoutActive else { return }
        activeMatch.shootoutStatus = .finished
        activeMatch.isLive = false
        activeMatch.isFinished = true
    }

    func endMatch() {
        guard let activeMatch else { return }
        normalizeMatchState(activeMatch)
        if activeMatch.isPenaltyShootoutActive {
            activeMatch.shootoutStatus = .finished
        }
        activeMatch.isLive = false
        activeMatch.isFinished = true
    }

    @discardableResult
    func log(
        eventType: MatchEventType,
        in match: MatchRecord,
        context: ModelContext,
        teamSide: TeamSide = .home,
        playerID: UUID? = nil,
        secondaryPlayerID: UUID? = nil,
        notes: String? = nil,
        source: SourceDevice = .iPhone,
        timestamp: Date = .now,
        createLinkedEvents: Bool = true
    ) throws -> MatchEventRecord {
        normalizeMatchState(match)
        try validateCanLog(eventType: eventType, to: match, teamSide: teamSide)
        let notesText = MatchFormat.sanitizedDisplayText(notes)
        let playerIDs = sanitizedPlayerIDs(
            for: eventType,
            in: match,
            teamSide: teamSide,
            primaryPlayerID: playerID,
            secondaryPlayerID: secondaryPlayerID
        )
        let createsSecondYellowRed = createLinkedEvents && shouldCreateSecondYellowRed(
            for: eventType,
            in: match,
            teamSide: teamSide,
            playerID: playerIDs.primary
        )
        let linkedGroupID = createLinkedEvents ? linkedGroupID(
            for: eventType,
            primaryPlayerID: playerIDs.primary,
            secondaryPlayerID: playerIDs.secondary,
            createsSecondYellowRed: createsSecondYellowRed
        ) : nil

        let event = insertEvent(
            eventType: eventType,
            in: match,
            context: context,
            teamSide: teamSide,
            playerID: playerIDs.primary,
            secondaryPlayerID: playerIDs.secondary,
            linkedGroupID: linkedGroupID,
            notes: notesText,
            source: source,
            timestamp: timestamp
        )

        if createLinkedEvents {
            insertLinkedEvents(
                for: eventType,
                in: match,
                context: context,
                teamSide: teamSide,
                primaryPlayerID: playerIDs.primary,
                secondaryPlayerID: playerIDs.secondary,
                linkedGroupID: linkedGroupID,
                notes: notesText,
                source: source,
                timestamp: timestamp,
                createsSecondYellowRed: createsSecondYellowRed
            )
        }

        try save(context)
        return event
    }

    @discardableResult
    private func insertEvent(
        eventType: MatchEventType,
        in match: MatchRecord,
        context: ModelContext,
        teamSide: TeamSide,
        playerID: UUID? = nil,
        secondaryPlayerID: UUID? = nil,
        linkedGroupID: UUID? = nil,
        notes: String? = nil,
        source: SourceDevice,
        timestamp: Date
    ) -> MatchEventRecord {
        match.homeScore = match.homeScoreValue
        match.awayScore = match.awayScoreValue
        match.homePenaltyScore = match.homePenaltyScoreValue
        match.awayPenaltyScore = match.awayPenaltyScoreValue

        let event = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: matchMinute(for: match),
            elapsedSeconds: match.elapsedClockSeconds,
            period: period(for: eventType, in: match),
            eventType: eventType,
            teamSide: teamSide,
            playerID: playerID,
            secondaryPlayerID: secondaryPlayerID,
            linkedGroupID: linkedGroupID,
            notes: notes,
            sourceDevice: source,
            match: match
        )

        match.events.append(event)

        if let scoringTeamSide = scoringTeamSide(for: eventType, committedBy: teamSide) {
            incrementScore(for: scoringTeamSide, in: match)
        }
        if eventType == .penaltyScored {
            incrementPenaltyScore(for: teamSide, in: match)
        }

        context.insert(event)
        return event
    }

    @discardableResult
    private func insertAssist(
        for match: MatchRecord,
        context: ModelContext,
        teamSide: TeamSide,
        playerID: UUID,
        linkedGroupID: UUID?,
        source: SourceDevice,
        timestamp: Date
    ) -> MatchEventRecord {
        let assistEvent = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: matchMinute(for: match),
            elapsedSeconds: match.elapsedClockSeconds,
            period: currentPeriod(for: match.currentPeriodNumber),
            eventType: .assist,
            teamSide: teamSide,
            playerID: playerID,
            linkedGroupID: linkedGroupID,
            notes: "Assist on goal",
            sourceDevice: source,
            match: match
        )

        match.events.append(assistEvent)
        context.insert(assistEvent)
        return assistEvent
    }

    func undoLastEvent(context: ModelContext) throws {
        guard let activeMatch else { return }
        try validateCanLog(to: activeMatch)
        normalizeMatchState(activeMatch)
        guard let latestEvent = activeMatch.events.sortedForRecentTimeline().first else { return }
        let eventsToUndo = activeMatch.events.linkedEventGroup(containing: latestEvent)
        guard !eventsToUndo.isEmpty else { return }

        delete(eventsToUndo, from: activeMatch, context: context)
        try save(context)
    }

    func deleteEventGroup(containing event: MatchEventRecord, in match: MatchRecord, context: ModelContext) throws {
        try validateCanLog(to: match)
        guard match.events.contains(where: { $0.id == event.id }) else { return }
        let eventsToDelete = match.events.linkedEventGroup(containing: event)
        guard !eventsToDelete.isEmpty else { return }
        normalizeMatchState(match)
        delete(eventsToDelete, from: match, context: context)
        try save(context)
    }

    private func delete(_ events: [MatchEventRecord], from match: MatchRecord, context: ModelContext) {
        for event in events {
            if event.hasValidRawValues,
               let eventType = event.validEventType,
               let teamSide = event.validTeamSide,
               let scoringTeamSide = scoringTeamSide(for: eventType, committedBy: teamSide) {
                decrementScore(for: scoringTeamSide, in: match)
            }
            if event.hasValidRawValues,
               event.validEventType == .penaltyScored,
               let teamSide = event.validTeamSide {
                decrementPenaltyScore(for: teamSide, in: match)
            }

            context.delete(event)
        }

        let deletedIDs = Set(events.map(\.id))
        match.events.removeAll { deletedIDs.contains($0.id) }
    }

    func applyDraft(_ draft: EventDraft, to match: MatchRecord, context: ModelContext, source: SourceDevice = .iPhone) throws {
        normalizeMatchState(match)
        try validateCanLog(eventType: draft.type, to: match, teamSide: draft.teamSide)

        let actionTimestamp = Date()
        let notesText = noteText(for: draft)
        let playerIDs = sanitizedPlayerIDs(
            for: draft.type,
            in: match,
            teamSide: draft.teamSide,
            primaryPlayerID: draft.primaryPlayerID,
            secondaryPlayerID: draft.secondaryPlayerID
        )
        let createsSecondYellowRed = shouldCreateSecondYellowRed(
            for: draft.type,
            in: match,
            teamSide: draft.teamSide,
            playerID: playerIDs.primary
        )
        let linkedGroupID = linkedGroupID(
            for: draft.type,
            primaryPlayerID: playerIDs.primary,
            secondaryPlayerID: playerIDs.secondary,
            createsSecondYellowRed: createsSecondYellowRed
        )

        insertEvent(
            eventType: draft.type,
            in: match,
            context: context,
            teamSide: draft.teamSide,
            playerID: playerIDs.primary,
            secondaryPlayerID: playerIDs.secondary,
            linkedGroupID: linkedGroupID,
            notes: notesText,
            source: source,
            timestamp: actionTimestamp
        )

        insertLinkedEvents(
            for: draft.type,
            in: match,
            context: context,
            teamSide: draft.teamSide,
            primaryPlayerID: playerIDs.primary,
            secondaryPlayerID: playerIDs.secondary,
            linkedGroupID: linkedGroupID,
            notes: notesText,
            source: source,
            timestamp: actionTimestamp,
            createsSecondYellowRed: createsSecondYellowRed
        )

        try save(context)
    }

    private func insertLinkedEvents(
        for eventType: MatchEventType,
        in match: MatchRecord,
        context: ModelContext,
        teamSide: TeamSide,
        primaryPlayerID: UUID?,
        secondaryPlayerID: UUID?,
        linkedGroupID: UUID?,
        notes: String?,
        source: SourceDevice,
        timestamp: Date,
        createsSecondYellowRed: Bool
    ) {
        if eventType == .goal, let secondaryPlayerID, secondaryPlayerID != primaryPlayerID {
            insertAssist(
                for: match,
                context: context,
                teamSide: teamSide,
                playerID: secondaryPlayerID,
                linkedGroupID: linkedGroupID,
                source: source,
                timestamp: timestamp
            )
        }

        if eventType == .foulCommitted {
            insertEvent(
                eventType: .foulWon,
                in: match,
                context: context,
                teamSide: opposingTeamSide(for: teamSide),
                linkedGroupID: linkedGroupID,
                notes: notes,
                source: source,
                timestamp: timestamp
            )
        }

        if createsSecondYellowRed, eventType == .yellowCard, let primaryPlayerID {
            insertEvent(
                eventType: .redCard,
                in: match,
                context: context,
                teamSide: teamSide,
                playerID: primaryPlayerID,
                linkedGroupID: linkedGroupID,
                notes: notes,
                source: source,
                timestamp: timestamp
            )
        }
    }

    private func linkedGroupID(
        for eventType: MatchEventType,
        primaryPlayerID: UUID?,
        secondaryPlayerID: UUID?,
        createsSecondYellowRed: Bool
    ) -> UUID? {
        if eventType == .goal, let secondaryPlayerID, secondaryPlayerID != primaryPlayerID {
            return UUID()
        }

        if eventType == .foulCommitted {
            return UUID()
        }

        if createsSecondYellowRed {
            return UUID()
        }

        return nil
    }

    private func shouldCreateSecondYellowRed(
        for eventType: MatchEventType,
        in match: MatchRecord,
        teamSide: TeamSide,
        playerID: UUID?
    ) -> Bool {
        guard eventType == .yellowCard, let playerID else { return false }

        let playerEvents = match.events.filter { event in
            event.hasValidRawValues
            && event.validTeamSide == teamSide
            && event.playerID == playerID
        }
        let yellowCardCount = playerEvents.filter { $0.validEventType == .yellowCard }.count
        let hasRedCard = playerEvents.contains { $0.validEventType == .redCard }

        return yellowCardCount == 1 && !hasRedCard
    }

    private func sanitizedPlayerIDs(
        for eventType: MatchEventType,
        in match: MatchRecord,
        teamSide: TeamSide,
        primaryPlayerID: UUID?,
        secondaryPlayerID: UUID?
    ) -> (primary: UUID?, secondary: UUID?) {
        let eligiblePlayerIDs = Set(match.players.filter { $0.validTeamSide == teamSide }.map(\.id))
        let primary = primaryPlayerID.flatMap { eligiblePlayerIDs.contains($0) ? $0 : nil }
        let secondary = secondaryPlayerID.flatMap { eligiblePlayerIDs.contains($0) ? $0 : nil }

        guard eventType == .goal || eventType == .substitution else {
            return (primary, nil)
        }

        if eventType == .substitution {
            let activePlayerIDs = match.liveActivePlayerIDs(for: teamSide)
            guard
                let primary,
                let secondary,
                primary != secondary,
                activePlayerIDs.contains(primary),
                !activePlayerIDs.contains(secondary)
            else {
                return (nil, nil)
            }
            return (primary, secondary)
        }

        if primary == secondary {
            return (primary, nil)
        }

        return (primary, secondary)
    }

    private func noteText(for draft: EventDraft) -> String? {
        let noteComponents = [draft.tag, draft.note].compactMap(MatchFormat.sanitizedDisplayText)
        return noteComponents.isEmpty ? nil : noteComponents.joined(separator: " • ")
    }

    private func currentPeriod(for half: Int) -> MatchPeriod {
        switch half {
        case ...1:
            .firstHalf
        case 2:
            .secondHalf
        case 3:
            .extraTimeFirstHalf
        case 4:
            .extraTimeSecondHalf
        default:
            .extraTime
        }
    }

    private func period(for eventType: MatchEventType, in match: MatchRecord) -> MatchPeriod {
        eventType.isShootoutAttempt ? .penalties : currentPeriod(for: match.currentPeriodNumber)
    }

    private func matchMinute(for match: MatchRecord) -> Int {
        max(1, (match.elapsedClockSeconds + 59) / 60)
    }

    private func opposingTeamSide(for teamSide: TeamSide) -> TeamSide {
        teamSide == .home ? .opponent : .home
    }

    private func scoringTeamSide(for eventType: MatchEventType, committedBy teamSide: TeamSide) -> TeamSide? {
        switch eventType {
        case .goal:
            teamSide
        case .ownGoal:
            opposingTeamSide(for: teamSide)
        default:
            nil
        }
    }

    private func incrementScore(for teamSide: TeamSide, in match: MatchRecord) {
        switch teamSide {
        case .home:
            match.homeScore = match.homeScoreValue + 1
        case .opponent:
            match.awayScore = match.awayScoreValue + 1
        }
    }

    private func decrementScore(for teamSide: TeamSide, in match: MatchRecord) {
        switch teamSide {
        case .home:
            match.homeScore = max(0, match.homeScoreValue - 1)
        case .opponent:
            match.awayScore = max(0, match.awayScoreValue - 1)
        }
    }

    private func incrementPenaltyScore(for teamSide: TeamSide, in match: MatchRecord) {
        switch teamSide {
        case .home:
            match.homePenaltyScore = match.homePenaltyScoreValue + 1
        case .opponent:
            match.awayPenaltyScore = match.awayPenaltyScoreValue + 1
        }
    }

    private func decrementPenaltyScore(for teamSide: TeamSide, in match: MatchRecord) {
        switch teamSide {
        case .home:
            match.homePenaltyScore = max(0, match.homePenaltyScoreValue - 1)
        case .opponent:
            match.awayPenaltyScore = max(0, match.awayPenaltyScoreValue - 1)
        }
    }

    private func normalizeMatchState(_ match: MatchRecord) {
        match.durationMinutes = match.durationMinuteValue
        match.extraTimeEnabled = match.usesExtraTime
        match.extraTimeHalfDurationMinutes = match.extraTimeHalfDurationMinuteValue
        match.shootoutStatusRawValue = match.shootoutStatus.rawValue
        match.homePenaltyScore = match.homePenaltyScoreValue
        match.awayPenaltyScore = match.awayPenaltyScoreValue
        match.substitutionLimitModeRawValue = match.substitutionLimitMode.rawValue
        match.substitutionLimit = match.substitutionLimitValue
        match.numberOfHalves = match.totalPeriodNumber
        match.currentHalf = match.currentPeriodNumber
        match.elapsedSeconds = match.elapsedClockSeconds
        match.homeScore = match.homeScoreValue
        match.awayScore = match.awayScoreValue
        if match.isFinished {
            match.isLive = false
        }
        normalizeRosterStarterState(for: match)
    }

    private func normalizeRosterStarterState(for match: MatchRecord) {
        for teamSide in TeamSide.allCases {
            let sidePlayers = match.players.filter { $0.validTeamSide == teamSide }
            guard !sidePlayers.isEmpty, !sidePlayers.contains(where: \.isStarter) else { continue }
            fallbackStarter(from: sidePlayers)?.isStarter = true
        }
    }

    private func fallbackStarter(from players: [PlayerRecord]) -> PlayerRecord? {
        players.sortedForPlayerSelection().first
    }

    private func validateCanLog(to match: MatchRecord) throws {
        if match.isFinished {
            throw MatchEngineError.matchFinished
        }
    }

    private func validateCanLog(eventType: MatchEventType, to match: MatchRecord, teamSide: TeamSide) throws {
        try validateCanLog(to: match)

        if match.isPenaltyShootoutActive {
            guard eventType.isShootoutAttempt else {
                throw MatchEngineError.shootoutActive
            }
            return
        }

        if eventType.isShootoutAttempt {
            throw MatchEngineError.shootoutNotActive
        }

        if eventType == .substitution, !match.canUseSubstitution(for: teamSide) {
            throw MatchEngineError.substitutionLimitReached
        }
    }

    private func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum MatchEngineError: LocalizedError, Equatable {
    case matchFinished
    case shootoutActive
    case shootoutNotActive
    case substitutionLimitReached

    var errorDescription: String? {
        switch self {
        case .matchFinished:
            "Match is already finished."
        case .shootoutActive:
            "Only penalty kicks can be logged during a shootout."
        case .shootoutNotActive:
            "Start penalty kicks before logging shootout attempts."
        case .substitutionLimitReached:
            "No substitutions remaining for this team."
        }
    }
}
