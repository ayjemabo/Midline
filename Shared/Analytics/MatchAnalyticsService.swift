import Foundation

@MainActor
struct MatchAnalyticsService {
    func buildSummary(for match: MatchRecord, scope: MatchAnalyticsScope = .home) -> MatchAnalyticsSummary {
        let scopedRawEvents = scopedEvents(for: match, scope: scope)
        let teamEvents = analyticsEvents(for: match, scopedEvents: scopedRawEvents)
        let counts = Dictionary(teamEvents.map(\.eventType).map { ($0, 1) }, uniquingKeysWith: +)
        let shootoutCounts = Dictionary(
            scopedRawEvents
                .compactMap(\.validEventType)
                .filter(\.isShootoutAttempt)
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        let totalShots = totalShots(from: counts)
        let attackInvolvement = attackInvolvement(from: counts)

        let teamTotals: [MatchStatLine] = [
            .init(title: "Goals", value: counts[.goal, default: 0]),
            .init(title: "Own Goals", value: counts[.ownGoal, default: 0]),
            .init(title: "Assists", value: counts[.assist, default: 0]),
            .init(title: "Shots On", value: counts[.shotOnTarget, default: 0]),
            .init(title: "Shots Off", value: counts[.shotOffTarget, default: 0]),
            .init(title: "Total Shots", value: totalShots),
            .init(title: "Key Passes", value: counts[.keyPass, default: 0]),
            .init(title: "Tackles Won", value: counts[.tackleWon, default: 0]),
            .init(title: "Interceptions", value: counts[.interception, default: 0]),
            .init(title: "Clearances", value: counts[.clearance, default: 0]),
            .init(title: "Saves", value: counts[.save, default: 0]),
            .init(title: "Fouls Committed", value: counts[.foulCommitted, default: 0]),
            .init(title: "Fouls Won", value: counts[.foulWon, default: 0]),
            .init(title: "Yellow Cards", value: counts[.yellowCard, default: 0]),
            .init(title: "Red Cards", value: counts[.redCard, default: 0]),
            .init(title: "Dribbles Completed", value: counts[.dribbleCompleted, default: 0]),
            .init(title: "Possession Lost", value: counts[.possessionLost, default: 0]),
            .init(title: "Corners Won", value: counts[.cornerWon, default: 0]),
            .init(title: "Offsides", value: counts[.offside, default: 0]),
            .init(title: "Pens Scored", value: shootoutCounts[.penaltyScored, default: 0]),
            .init(title: "Pens Missed", value: shootoutCounts[.penaltyMissed, default: 0]),
            .init(title: "Pens Saved", value: shootoutCounts[.penaltySaved, default: 0])
        ]

        let playerStats = playerSummaries(for: match, events: teamEvents)

        return MatchAnalyticsSummary(
            scoreLine: match.displayScoreLine,
            teamTotals: teamTotals,
            attackInvolvement: attackInvolvement,
            defensiveInvolvement: counts[.tackleWon, default: 0] + counts[.interception, default: 0] + counts[.clearance, default: 0] + counts[.save, default: 0],
            discipline: counts[.foulCommitted, default: 0] + counts[.yellowCard, default: 0] + counts[.redCard, default: 0],
            ballRetentionImpact: counts[.dribbleCompleted, default: 0] - counts[.possessionLost, default: 0],
            mostActivePlayer: topPlayer(from: playerStats, scoring: totalScore),
            topAttackingContributor: topPlayer(from: playerStats, scoring: attackScore),
            topDefensiveContributor: topPlayer(from: playerStats, scoring: defenseScore)
        )
    }

    private func totalShots(from counts: [MatchEventType: Int]) -> Int {
        counts[.goal, default: 0]
        + counts[.shotOnTarget, default: 0]
        + counts[.shotOffTarget, default: 0]
    }

    private func attackInvolvement(from counts: [MatchEventType: Int]) -> Int {
        counts[.assist, default: 0]
        + counts[.keyPass, default: 0]
        + totalShots(from: counts)
    }

    private func scopedEvents(for match: MatchRecord, scope: MatchAnalyticsScope) -> [MatchEventRecord] {
        match.events.filter { event in
            guard event.hasValidRawValues, let teamSide = event.validTeamSide else { return false }
            return scope.includes(teamSide)
        }
    }

    private func analyticsEvents(for match: MatchRecord, scopedEvents: [MatchEventRecord]) -> [AnalyticsEvent] {
        let baseEvents = scopedEvents.compactMap(AnalyticsEvent.init)
        let inferredAssists = scopedEvents.compactMap { event -> AnalyticsEvent? in
            guard
                event.validEventType == .goal,
                let teamSide = event.validTeamSide,
                let secondaryPlayerID = event.secondaryPlayerID,
                event.playerID != secondaryPlayerID,
                match.player(id: secondaryPlayerID, teamSide: teamSide) != nil,
                !hasLinkedAssist(for: event, in: match.events)
            else {
                return nil
            }

            return AnalyticsEvent(eventType: .assist, teamSide: teamSide, playerID: secondaryPlayerID)
        }

        return baseEvents + inferredAssists
    }

    private func hasLinkedAssist(for goal: MatchEventRecord, in events: [MatchEventRecord]) -> Bool {
        if let linkedGroupID = goal.linkedGroupID {
            return events.contains { event in
                event.hasValidRawValues
                && event.validEventType == .assist
                && event.linkedGroupID == linkedGroupID
                && event.timestamp == goal.timestamp
                && event.validTeamSide == goal.validTeamSide
                && event.playerID == goal.secondaryPlayerID
            }
        }

        return events.contains { event in
            event.hasValidRawValues
            && event.validEventType == .assist
            && event.linkedGroupID == nil
            && event.timestamp == goal.timestamp
            && event.validTeamSide == goal.validTeamSide
            && event.playerID == goal.secondaryPlayerID
        }
    }

    private func playerSummaries(for match: MatchRecord, events: [AnalyticsEvent]) -> [PlayerStatSummary] {
        let keyedEvents = events.compactMap { event -> (key: AnalyticsPlayerKey, event: AnalyticsEvent)? in
            guard
                let playerID = event.playerID,
                match.player(id: playerID, teamSide: event.teamSide) != nil
            else { return nil }

            return (.init(playerID: playerID, teamSide: event.teamSide), event)
        }
        let byPlayer = Dictionary(grouping: keyedEvents, by: \.key)

        return byPlayer.compactMap { entry in
            let key = entry.key
            guard let player = match.player(id: key.playerID, teamSide: key.teamSide) else { return nil }
            let stats = Dictionary(entry.value.map(\.event.eventType).map { ($0, 1) }, uniquingKeysWith: +)
            return PlayerStatSummary(
                playerID: key.playerID,
                teamSide: key.teamSide,
                playerName: player.displayName,
                stats: stats
            )
        }
    }

    private func attackScore(_ summary: PlayerStatSummary) -> Int {
        attackInvolvement(from: summary.stats)
    }

    private func defenseScore(_ summary: PlayerStatSummary) -> Int {
        summary.stats[.tackleWon, default: 0] + summary.stats[.interception, default: 0] + summary.stats[.clearance, default: 0] + summary.stats[.save, default: 0]
    }

    private func totalScore(_ summary: PlayerStatSummary) -> Int {
        summary.stats.values.reduce(0, +)
    }

    private func topPlayer(
        from summaries: [PlayerStatSummary],
        scoring: (PlayerStatSummary) -> Int
    ) -> PlayerStatSummary? {
        summaries.filter { scoring($0) > 0 }.sorted { lhs, rhs in
            let leftScore = scoring(lhs)
            let rightScore = scoring(rhs)
            if leftScore != rightScore {
                return leftScore > rightScore
            }
            let nameOrder = lhs.playerName.localizedCaseInsensitiveCompare(rhs.playerName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if lhs.playerID != rhs.playerID {
                return lhs.playerID.uuidString < rhs.playerID.uuidString
            }
            return lhs.teamSide.rawValue < rhs.teamSide.rawValue
        }.first
    }
}

private struct AnalyticsPlayerKey: Hashable {
    let playerID: UUID
    let teamSide: TeamSide
}

private struct AnalyticsEvent {
    let eventType: MatchEventType
    let teamSide: TeamSide
    let playerID: UUID?

    init(eventType: MatchEventType, teamSide: TeamSide, playerID: UUID?) {
        self.eventType = eventType
        self.teamSide = teamSide
        self.playerID = playerID
    }

    init?(_ event: MatchEventRecord) {
        guard let eventType = event.validEventType, let teamSide = event.validTeamSide else { return nil }
        guard !eventType.isShootoutAttempt else { return nil }
        self.init(eventType: eventType, teamSide: teamSide, playerID: event.playerID)
    }
}
