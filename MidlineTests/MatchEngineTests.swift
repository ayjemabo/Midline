import Foundation
import SQLite3
import SwiftData
import XCTest

@MainActor
final class MatchEngineTests: XCTestCase {
    func testGoalDeleteRemovesEventAndCorrectsHomeScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.count, 1)

        let event = try XCTUnwrap(match.events.first)
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeleteEventGroupNormalizesLegacyMatchStateBeforeSaving() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100.5),
            matchMinute: 5,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            match: match
        )
        match.events.append(event)
        context.insert(match)
        context.insert(event)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testOpponentGoalDeleteCorrectsOpponentScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .opponent,
            timestamp: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)

        let event = try XCTUnwrap(match.events.first)
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testHomeOwnGoalAwardsOpponentScoreWithoutAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let defender = PlayerRecord(name: "Defender", teamSide: .home, match: match)
        let teammate = PlayerRecord(name: "Teammate", teamSide: .home, match: match)
        match.players.append(contentsOf: [defender, teammate])
        context.insert(match)
        context.insert(defender)
        context.insert(teammate)

        let engine = MatchEngine()
        try engine.log(
            eventType: .ownGoal,
            in: match,
            context: context,
            teamSide: .home,
            playerID: defender.id,
            secondaryPlayerID: teammate.id,
            timestamp: Date(timeIntervalSince1970: 102.1)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.ownGoal])
        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.playerID, defender.id)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testOpponentOwnGoalAwardsHomeScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        let defender = PlayerRecord(name: "Opponent Defender", teamSide: .opponent, match: match)
        match.players.append(defender)
        context.insert(match)
        context.insert(defender)

        let engine = MatchEngine()
        try engine.log(
            eventType: .ownGoal,
            in: match,
            context: context,
            teamSide: .opponent,
            playerID: defender.id,
            timestamp: Date(timeIntervalSince1970: 102.2)
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.ownGoal])
    }

    func testShotOnTargetLogCreatesSingleTimelineEvent() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 102.25)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.count, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.shotOnTarget])
        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.shotOnTarget])
    }

    func testFirstYellowCardDoesNotCreateRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(
            eventType: .yellowCard,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            timestamp: Date(timeIntervalSince1970: 102.26)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard])
        XCTAssertNil(match.events.first?.linkedGroupID)
    }

    func testSecondYellowCardCreatesLinkedRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(
            eventType: .yellowCard,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            timestamp: Date(timeIntervalSince1970: 102.27)
        )
        try engine.log(
            eventType: .yellowCard,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            notes: "Late tackle",
            timestamp: Date(timeIntervalSince1970: 102.28)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.yellowCard, .yellowCard, .redCard])
        let secondYellow = try XCTUnwrap(match.events.first { $0.eventType == .yellowCard && $0.linkedGroupID != nil })
        let red = try XCTUnwrap(match.events.first { $0.eventType == .redCard })
        XCTAssertNotNil(secondYellow.linkedGroupID)
        XCTAssertEqual(secondYellow.linkedGroupID, red.linkedGroupID)
        XCTAssertEqual(secondYellow.playerID, player.id)
        XCTAssertEqual(red.playerID, player.id)
        XCTAssertEqual(red.notesText, "Late tackle")
        XCTAssertEqual(match.events.linkedEventGroup(containing: secondYellow).sortedForTimeline().map(\.eventType), [.yellowCard, .redCard])
    }

    func testSecondYellowDraftCreatesLinkedRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(type: .yellowCard, teamSide: .home, primaryPlayerID: player.id),
            to: match,
            context: context
        )
        try engine.applyDraft(
            EventDraft(type: .yellowCard, teamSide: .home, primaryPlayerID: player.id, note: "Second booking"),
            to: match,
            context: context
        )

        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.yellowCard, .yellowCard, .redCard])
        let secondYellow = try XCTUnwrap(match.events.first { $0.eventType == .yellowCard && $0.linkedGroupID != nil })
        let red = try XCTUnwrap(match.events.first { $0.eventType == .redCard })
        XCTAssertEqual(secondYellow.linkedGroupID, red.linkedGroupID)
        XCTAssertEqual(red.notesText, "Second booking")
    }

    func testSecondYellowDoesNotTriggerForAnotherPlayerOrTeam() throws {
        let context = try makeContext()
        let match = makeMatch()
        let homePlayer = PlayerRecord(name: "Home Player", teamSide: .home, match: match)
        let teammate = PlayerRecord(name: "Teammate", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [homePlayer, teammate, opponentPlayer])
        context.insert(match)
        context.insert(homePlayer)
        context.insert(teammate)
        context.insert(opponentPlayer)

        let engine = MatchEngine()
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: homePlayer.id)
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: teammate.id)
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .opponent, playerID: opponentPlayer.id)

        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard, .yellowCard, .yellowCard])
    }

    func testExistingRedCardPreventsDuplicateSecondYellowRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id)
        try engine.log(eventType: .redCard, in: match, context: context, teamSide: .home, playerID: player.id)
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id)

        XCTAssertEqual(match.events.filter { $0.eventType == .yellowCard }.count, 2)
        XCTAssertEqual(match.events.filter { $0.eventType == .redCard }.count, 1)
        XCTAssertTrue(match.events.allSatisfy { $0.linkedGroupID == nil })
    }

    func testTeamLevelYellowCardsDoNotCreateRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home)
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home)

        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard, .yellowCard])
        XCTAssertTrue(match.events.allSatisfy { $0.playerID == nil })
    }

    func testUndoSecondYellowRemovesLinkedRedCard() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.29))
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.30))

        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.yellowCard, .yellowCard, .redCard])

        try engine.undoLastEvent(context: context)

        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard])
    }

    func testDeleteSecondYellowRedCardGroupLeavesFirstYellow() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.31))
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.32))

        let red = try XCTUnwrap(match.events.first { $0.eventType == .redCard })
        try engine.deleteEventGroup(containing: red, in: match, context: context)

        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard])
    }

    func testDeletingFirstYellowDoesNotRemoveLaterSecondYellowRedCardGroup() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.33))
        try engine.log(eventType: .yellowCard, in: match, context: context, teamSide: .home, playerID: player.id, timestamp: Date(timeIntervalSince1970: 102.34))

        let firstYellow = try XCTUnwrap(match.events.first { $0.eventType == .yellowCard && $0.linkedGroupID == nil })
        try engine.deleteEventGroup(containing: firstYellow, in: match, context: context)

        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.yellowCard, .redCard])
    }

    func testUndoOwnGoalRestoresCorrectScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(
            eventType: .ownGoal,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 102.3)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)

        try engine.undoLastEvent(context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeleteOwnGoalRestoresCorrectScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .ownGoal,
            in: match,
            context: context,
            teamSide: .opponent,
            timestamp: Date(timeIntervalSince1970: 102.4)
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)

        let event = try XCTUnwrap(match.events.first)
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingInvalidRawEventDoesNotChangeScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let invalidEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 102),
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidEvent.eventTypeRawValue = "legacyEvent"
        match.events.append(invalidEvent)
        context.insert(match)
        context.insert(invalidEvent)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: invalidEvent, in: match, context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingGoalWithInvalidRawTeamSideDoesNotChangeScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        match.awayScore = 1
        let invalidEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 102.5),
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidEvent.teamSideRawValue = "visitor"
        match.events.append(invalidEvent)
        context.insert(match)
        context.insert(invalidEvent)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: invalidEvent, in: match, context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingGoalWithInvalidRawPeriodDoesNotChangeScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let invalidEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 102.75),
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidEvent.periodRawValue = "futurePeriod"
        match.events.append(invalidEvent)
        context.insert(match)
        context.insert(invalidEvent)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: invalidEvent, in: match, context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingEventFromDifferentMatchDoesNotDeleteSameTimestampEvents() throws {
        let context = try makeContext()
        let match = makeMatch()
        let otherMatch = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103)
        let event = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        let otherEvent = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: otherMatch
        )
        match.events.append(event)
        otherMatch.events.append(otherEvent)
        context.insert(match)
        context.insert(otherMatch)
        context.insert(event)
        context.insert(otherEvent)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: otherEvent, in: match, context: context)

        XCTAssertEqual(match.events.map(\.id), [event.id])
        XCTAssertEqual(otherMatch.events.map(\.id), [otherEvent.id])
    }

    func testDeletingEventDoesNotDeleteUnrelatedSameTimestampEvent() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.25)
        let goal = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        let unrelatedShot = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 2,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            match: match
        )
        match.events.append(contentsOf: [goal, unrelatedShot])
        context.insert(match)
        context.insert(goal)
        context.insert(unrelatedShot)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.events.map(\.id), [unrelatedShot.id])
    }

    func testDeletingAnonymousGoalDoesNotDeleteAnonymousSameTimestampAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let sharedTimestamp = Date(timeIntervalSince1970: 103.27)
        let goal = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        let unrelatedAssist = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            match: match
        )
        match.events.append(contentsOf: [goal, unrelatedAssist])
        context.insert(match)
        context.insert(goal)
        context.insert(unrelatedAssist)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.events.map(\.id), [unrelatedAssist.id])
    }

    func testDeletingGoalDraftAlsoDeletesLinkedAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        match.players.append(contentsOf: [scorer, assister])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .goal,
                teamSide: .home,
                primaryPlayerID: scorer.id,
                secondaryPlayerID: assister.id,
                tag: "Open Play"
            ),
            to: match,
            context: context
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(Set(match.events.map(\.eventType)), [.goal, .assist])

        let goal = try XCTUnwrap(match.events.first { $0.eventType == .goal })
        let assist = try XCTUnwrap(match.events.first { $0.eventType == .assist })
        XCTAssertNotNil(goal.linkedGroupID)
        XCTAssertEqual(goal.linkedGroupID, assist.linkedGroupID)
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDirectGoalLogCreatesAndDeletesLinkedAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        match.players.append(contentsOf: [scorer, assister])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            timestamp: Date(timeIntervalSince1970: 103)
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(Set(match.events.map(\.eventType)), [.goal, .assist])

        let goal = try XCTUnwrap(match.events.first { $0.eventType == .goal })
        let assist = try XCTUnwrap(match.events.first { $0.eventType == .assist })
        XCTAssertNotNil(goal.linkedGroupID)
        XCTAssertEqual(goal.linkedGroupID, assist.linkedGroupID)
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingGroupedGoalLeavesInvalidPeriodLinkedAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 103.05)
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let invalidAssist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            playerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        invalidAssist.periodRawValue = "futurePeriod"
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [goal, invalidAssist])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)
        context.insert(goal)
        context.insert(invalidAssist)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.events.map(\.id), [invalidAssist.id])
    }

    func testDeletingGroupedGoalLeavesInvalidTypeLinkedAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 103.07)
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let invalidAssist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            playerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        invalidAssist.eventTypeRawValue = "legacyEvent"
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [goal, invalidAssist])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)
        context.insert(goal)
        context.insert(invalidAssist)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.events.map(\.id), [invalidAssist.id])
    }

    func testDeletingInvalidGroupedAssistDoesNotDeleteValidGoal() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 103.08)
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let invalidAssist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 5,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            playerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        invalidAssist.teamSideRawValue = "visitor"
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [goal, invalidAssist])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)
        context.insert(goal)
        context.insert(invalidAssist)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: invalidAssist, in: match, context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.events.map(\.id), [goal.id])
    }

    func testDirectFoulLogCreatesGroupedWonFoul() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .foulCommitted,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 103.1)
        )

        let committed = try XCTUnwrap(match.events.first { $0.eventType == .foulCommitted })
        let won = try XCTUnwrap(match.events.first { $0.eventType == .foulWon })
        XCTAssertEqual(committed.teamSide, .home)
        XCTAssertEqual(won.teamSide, .opponent)
        XCTAssertNotNil(committed.linkedGroupID)
        XCTAssertEqual(committed.linkedGroupID, won.linkedGroupID)
    }

    func testDeletingLegacyFoulPairDeletesSingleUngroupedCounterpart() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.15)
        let committed = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulCommitted,
            teamSide: .home,
            match: match
        )
        let won = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            match: match
        )
        match.events.append(contentsOf: [committed, won])
        context.insert(match)
        context.insert(committed)
        context.insert(won)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: committed, in: match, context: context)

        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingLegacyFoulPairLeavesInvalidPeriodCounterpart() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.16)
        let committed = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulCommitted,
            teamSide: .home,
            match: match
        )
        let invalidWon = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            match: match
        )
        invalidWon.periodRawValue = "futurePeriod"
        match.events.append(contentsOf: [committed, invalidWon])
        context.insert(match)
        context.insert(committed)
        context.insert(invalidWon)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: committed, in: match, context: context)

        XCTAssertEqual(match.events.map(\.id), [invalidWon.id])
    }

    func testDeletingAmbiguousLegacyFoulPairDeletesOnlySelectedEvent() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.18)
        let committed = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulCommitted,
            teamSide: .home,
            match: match
        )
        let firstWon = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            match: match
        )
        let secondWon = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            match: match
        )
        match.events.append(contentsOf: [committed, firstWon, secondWon])
        context.insert(match)
        context.insert(committed)
        context.insert(firstWon)
        context.insert(secondWon)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: committed, in: match, context: context)

        XCTAssertEqual(Set(match.events.map(\.id)), Set([firstWon.id, secondWon.id]))
    }

    func testDirectSingleEventLogDoesNotCreateLinkedGroup() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            timestamp: Date(timeIntervalSince1970: 103.2)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertNil(event.linkedGroupID)
    }

    func testDeletingGroupedEventDoesNotUseLegacyTimestampFallback() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.3)
        let linkedGroupID = UUID()
        let committed = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulCommitted,
            teamSide: .home,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let won = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let unrelatedLegacyWon = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .foulWon,
            teamSide: .opponent,
            match: match
        )
        match.events.append(contentsOf: [committed, won, unrelatedLegacyWon])
        context.insert(match)
        context.insert(committed)
        context.insert(won)
        context.insert(unrelatedLegacyWon)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: committed, in: match, context: context)

        XCTAssertEqual(match.events.map(\.id), [unrelatedLegacyWon.id])
    }

    func testDeletingGroupedEventLeavesUnrelatedEventWithSameGroupID() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let sharedTimestamp = Date(timeIntervalSince1970: 103.35)
        let goal = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let assist = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            playerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let unrelatedCard = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 6,
            period: .firstHalf,
            eventType: .yellowCard,
            teamSide: .home,
            playerID: scorer.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [goal, assist, unrelatedCard])
        context.insert(match)
        context.insert(scorer)
        context.insert(assister)
        context.insert(goal)
        context.insert(assist)
        context.insert(unrelatedCard)

        let engine = MatchEngine()
        try engine.deleteEventGroup(containing: goal, in: match, context: context)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.events.map(\.id), [unrelatedCard.id])
    }

    func testDirectLoggingDropsBlankNotes() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            notes: " \n\t ",
            timestamp: Date(timeIntervalSince1970: 103.5)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertNil(event.notes)
        XCTAssertNil(event.notesText)
    }

    func testDraftLoggingTrimsNoteComponents() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .shotOnTarget,
                teamSide: .home,
                note: "  Curled far post  ",
                tag: "  Open Play  "
            ),
            to: match,
            context: context
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.notes, "Open Play • Curled far post")
        XCTAssertEqual(event.notesText, "Open Play • Curled far post")
    }

    func testEventDraftWithoutOptionalDetailPreservesEventAndSideOnly() {
        let primaryID = UUID()
        let secondaryID = UUID()
        var draft = EventDraft(type: .goal, teamSide: .opponent)
        draft.primaryPlayerID = primaryID
        draft.secondaryPlayerID = secondaryID
        draft.tag = "Open Play"
        draft.note = "Near post"

        let strippedDraft = draft.withoutOptionalDetail

        XCTAssertEqual(strippedDraft.type, .goal)
        XCTAssertEqual(strippedDraft.teamSide, .opponent)
        XCTAssertNil(strippedDraft.primaryPlayerID)
        XCTAssertNil(strippedDraft.secondaryPlayerID)
        XCTAssertTrue(strippedDraft.tag.isEmpty)
        XCTAssertTrue(strippedDraft.note.isEmpty)
    }

    func testLegacyWhitespaceNotesAreHiddenFromDisplayText() throws {
        let event = MatchEventRecord(
            matchMinute: 7,
            period: .firstHalf,
            eventType: .shotOffTarget,
            notes: "  Rushed finish  "
        )

        XCTAssertEqual(event.notes, "Rushed finish")
        XCTAssertEqual(event.notesText, "Rushed finish")

        event.notes = "\n\t"

        XCTAssertNil(event.notesText)
    }

    func testGoalDraftDoesNotCreateSelfAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        match.players.append(scorer)
        context.insert(match)
        context.insert(scorer)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .goal,
                teamSide: .home,
                primaryPlayerID: scorer.id,
                secondaryPlayerID: scorer.id
            ),
            to: match,
            context: context
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testDirectGoalLogDoesNotCreateSelfAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        match.players.append(scorer)
        context.insert(match)
        context.insert(scorer)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: scorer.id,
            timestamp: Date(timeIntervalSince1970: 106)
        )

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testSubstitutionDraftClearsSamePlayerOnAndOff() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Midfielder", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .substitution,
                teamSide: .home,
                primaryPlayerID: player.id,
                secondaryPlayerID: player.id
            ),
            to: match,
            context: context
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .substitution)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testDirectSubstitutionLogClearsSamePlayerOnAndOff() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Midfielder", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(
            eventType: .substitution,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            secondaryPlayerID: player.id,
            timestamp: Date(timeIntervalSince1970: 107)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .substitution)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testDirectSubstitutionLogDropsIncompletePlayerPair() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Midfielder", teamSide: .home, match: match)
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(
            eventType: .substitution,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            timestamp: Date(timeIntervalSince1970: 107.5)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .substitution)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testDirectSubstitutionLogDropsPairWhenOnePlayerIsIneligible() throws {
        let context = try makeContext()
        let match = makeMatch()
        let homePlayer = PlayerRecord(name: "Home Player", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [homePlayer, opponentPlayer])
        context.insert(match)
        context.insert(homePlayer)
        context.insert(opponentPlayer)

        let engine = MatchEngine()
        try engine.log(
            eventType: .substitution,
            in: match,
            context: context,
            teamSide: .home,
            playerID: homePlayer.id,
            secondaryPlayerID: opponentPlayer.id,
            timestamp: Date(timeIntervalSince1970: 107.7)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .substitution)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testDirectSubstitutionLogDropsActivePlayerComingOn() throws {
        let context = try makeContext()
        let match = makeMatch()
        let playerOff = PlayerRecord(name: "Player Off", isStarter: true, teamSide: .home, match: match)
        let alreadyActive = PlayerRecord(name: "Already Active", isStarter: true, teamSide: .home, match: match)
        match.players.append(contentsOf: [playerOff, alreadyActive])
        context.insert(match)
        context.insert(playerOff)
        context.insert(alreadyActive)

        let engine = MatchEngine()
        try engine.log(
            eventType: .substitution,
            in: match,
            context: context,
            teamSide: .home,
            playerID: playerOff.id,
            secondaryPlayerID: alreadyActive.id,
            timestamp: Date(timeIntervalSince1970: 107.9)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .substitution)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testGoalDraftDropsPlayerIDsOutsideSelectedTeam() throws {
        let context = try makeContext()
        let match = makeMatch()
        let homePlayer = PlayerRecord(name: "Home Player", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [homePlayer, opponentPlayer])
        context.insert(match)
        context.insert(homePlayer)
        context.insert(opponentPlayer)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .goal,
                teamSide: .home,
                primaryPlayerID: opponentPlayer.id,
                secondaryPlayerID: homePlayer.id
            ),
            to: match,
            context: context
        )

        let goal = try XCTUnwrap(match.events.first { $0.eventType == .goal })
        let assist = try XCTUnwrap(match.events.first { $0.eventType == .assist })
        XCTAssertNil(goal.playerID)
        XCTAssertEqual(goal.secondaryPlayerID, homePlayer.id)
        XCTAssertEqual(assist.playerID, homePlayer.id)
        XCTAssertEqual(match.homeScore, 1)
    }

    func testDirectGoalLogDropsWrongSideAssist() throws {
        let context = try makeContext()
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [scorer, opponentPlayer])
        context.insert(match)
        context.insert(scorer)
        context.insert(opponentPlayer)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: opponentPlayer.id,
            timestamp: Date(timeIntervalSince1970: 108)
        )

        let goal = try XCTUnwrap(match.events.first)
        XCTAssertEqual(goal.eventType, .goal)
        XCTAssertEqual(goal.playerID, scorer.id)
        XCTAssertNil(goal.secondaryPlayerID)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testDirectLoggingDropsPlayerWithInvalidRawTeamSide() throws {
        let context = try makeContext()
        let match = makeMatch()
        let player = PlayerRecord(name: "Legacy Player", teamSide: .home, match: match)
        player.teamSideRawValue = "visitor"
        match.players.append(player)
        context.insert(match)
        context.insert(player)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            playerID: player.id,
            timestamp: Date(timeIntervalSince1970: 108.5)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .shotOnTarget)
        XCTAssertNil(event.playerID)
        XCTAssertNil(player.validTeamSide)
    }

    func testDirectLoggingDropsUnknownPlayerIDs() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            playerID: UUID(),
            secondaryPlayerID: UUID(),
            timestamp: Date(timeIntervalSince1970: 109)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .shotOnTarget)
        XCTAssertNil(event.playerID)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testDirectLoggingDropsSecondaryPlayerForSinglePlayerEvents() throws {
        let context = try makeContext()
        let match = makeMatch()
        let primary = PlayerRecord(name: "Shooter", teamSide: .home, match: match)
        let secondary = PlayerRecord(name: "Teammate", teamSide: .home, match: match)
        match.players.append(contentsOf: [primary, secondary])
        context.insert(match)
        context.insert(primary)
        context.insert(secondary)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            playerID: primary.id,
            secondaryPlayerID: secondary.id,
            timestamp: Date(timeIntervalSince1970: 109.5)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .shotOnTarget)
        XCTAssertEqual(event.playerID, primary.id)
        XCTAssertNil(event.secondaryPlayerID)
    }

    func testLoggingAfterSecondHalfUsesExtraTimePeriod() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.numberOfHalves = 4
        match.currentHalf = 3
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 104)
        )

        XCTAssertEqual(match.events.map(\.period), [.extraTimeFirstHalf])
    }

    func testLinkedEventsAfterSecondHalfUseExtraTimePeriod() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.numberOfHalves = 4
        match.currentHalf = 3
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .foulCommitted,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 105)
        )

        XCTAssertEqual(Set(match.events.map(\.eventType)), [.foulCommitted, .foulWon])
        XCTAssertEqual(Set(match.events.map(\.period)), [.extraTimeFirstHalf])
    }

    func testLoggingInSecondExtraTimeHalfUsesDistinctPeriod() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.extraTimeEnabled = true
        match.numberOfHalves = 4
        match.currentHalf = 4
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 105.5)
        )

        XCTAssertEqual(match.events.map(\.period), [.extraTimeSecondHalf])
    }

    func testClearActiveMatchOnlyClearsMatchingMatch() {
        let active = makeMatch()
        let other = makeMatch()
        let engine = MatchEngine()

        engine.select(match: active)
        XCTAssertFalse(engine.clearActiveMatch(ifMatching: other))

        XCTAssertIdentical(engine.activeMatch, active)

        XCTAssertTrue(engine.clearActiveMatch(ifMatching: active))

        XCTAssertNil(engine.activeMatch)
    }

    func testClearActiveMatchCanUseCapturedMatchID() {
        let active = makeMatch()
        let other = makeMatch()
        let engine = MatchEngine()

        engine.select(match: active)
        XCTAssertFalse(engine.clearActiveMatch(ifMatchingID: other.id))

        XCTAssertIdentical(engine.activeMatch, active)

        XCTAssertTrue(engine.clearActiveMatch(ifMatchingID: active.id))

        XCTAssertNil(engine.activeMatch)
    }

    func testClearActiveMatchIfFinishedClearsOnlyFinishedMatchingMatch() {
        let active = makeMatch()
        let engine = MatchEngine()

        engine.select(match: active)
        XCTAssertFalse(engine.clearActiveMatchIfFinished(active))
        XCTAssertIdentical(engine.activeMatch, active)

        active.isFinished = true
        XCTAssertTrue(engine.clearActiveMatchIfFinished(active))
        XCTAssertNil(engine.activeMatch)
    }

    func testClearActiveMatchIfFinishedDoesNotClearDifferentActiveMatch() {
        let active = makeMatch()
        let finishedOther = makeMatch()
        finishedOther.isFinished = true
        let engine = MatchEngine()

        engine.select(match: active)
        XCTAssertFalse(engine.clearActiveMatchIfFinished(finishedOther))

        XCTAssertIdentical(engine.activeMatch, active)
    }

    func testStartSelectsMatchAndMarksItLive() {
        let match = makeMatch()
        match.isLive = false
        match.isFinished = true
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertIdentical(engine.activeMatch, match)
        XCTAssertTrue(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testStartPausesPreviousActiveMatch() {
        let previousActive = makeMatch()
        previousActive.isLive = true
        previousActive.isFinished = false
        let match = makeMatch()
        let engine = MatchEngine()
        engine.select(match: previousActive)

        engine.start(match: match)

        XCTAssertIdentical(engine.activeMatch, match)
        XCTAssertFalse(previousActive.isLive)
        XCTAssertFalse(previousActive.isFinished)
        XCTAssertTrue(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testRestoreSelectsAndNormalizesWithoutResumingPausedMatch() {
        let match = makeMatch()
        match.isLive = false
        match.isFinished = false
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let player = PlayerRecord(
            name: "Fallback",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        match.players.append(player)
        let engine = MatchEngine()

        engine.restore(match: match)

        XCTAssertIdentical(engine.activeMatch, match)
        XCTAssertFalse(match.isLive)
        XCTAssertFalse(match.isFinished)
        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(player.isStarter)
    }

    func testRestoreNormalizesFinishedMatchAsNotLive() {
        let match = makeMatch()
        match.isLive = true
        match.isFinished = true

        MatchEngine().restore(match: match)

        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testRestorePreferredActiveMatchNormalizesReplacementWithoutResumingPausedMatch() {
        let deletedActive = makeMatch()
        deletedActive.date = Date(timeIntervalSince1970: 300)
        let replacement = makeMatch()
        replacement.date = Date(timeIntervalSince1970: 200)
        replacement.isLive = false
        replacement.isFinished = false
        replacement.durationMinutes = 999
        replacement.numberOfHalves = 99
        replacement.currentHalf = 99
        replacement.elapsedSeconds = -9
        replacement.homeScore = -2
        replacement.awayScore = -3
        let player = PlayerRecord(
            name: "Fallback",
            isStarter: false,
            teamSide: .home,
            match: replacement
        )
        replacement.players.append(player)
        let engine = MatchEngine()
        engine.select(match: deletedActive)

        let restored = engine.restorePreferredActiveMatch(
            afterDeletingIDs: [deletedActive.id],
            from: [replacement]
        )

        XCTAssertIdentical(restored, replacement)
        XCTAssertIdentical(engine.activeMatch, replacement)
        XCTAssertFalse(replacement.isLive)
        XCTAssertFalse(replacement.isFinished)
        XCTAssertEqual(replacement.durationMinutes, 130)
        XCTAssertEqual(replacement.numberOfHalves, 4)
        XCTAssertEqual(replacement.currentHalf, 4)
        XCTAssertEqual(replacement.elapsedSeconds, 0)
        XCTAssertEqual(replacement.homeScore, 0)
        XCTAssertEqual(replacement.awayScore, 0)
        XCTAssertTrue(player.isStarter)
    }

    func testRestorePreferredActiveMatchClearsDeletedActiveWhenNoReplacementExists() {
        let deletedActive = makeMatch()
        let engine = MatchEngine()
        engine.select(match: deletedActive)

        let restored = engine.restorePreferredActiveMatch(
            afterDeletingIDs: [deletedActive.id],
            from: []
        )

        XCTAssertNil(restored)
        XCTAssertNil(engine.activeMatch)
    }

    func testRestoreActiveMatchAfterFailedStartRestoresPreviousActiveMatch() {
        let previousActive = makeMatch()
        previousActive.isLive = false
        previousActive.isFinished = false
        previousActive.durationMinutes = 999
        previousActive.numberOfHalves = 99
        previousActive.currentHalf = 99
        previousActive.elapsedSeconds = -9
        previousActive.homeScore = -2
        previousActive.awayScore = -3
        let player = PlayerRecord(
            name: "Fallback",
            isStarter: false,
            teamSide: .home,
            match: previousActive
        )
        previousActive.players.append(player)
        let failedMatch = makeMatch()
        let engine = MatchEngine()
        engine.select(match: previousActive)
        engine.start(match: failedMatch)

        engine.restoreActiveMatchAfterFailedStart(
            failedMatchID: failedMatch.id,
            previousActiveMatch: previousActive
        )

        XCTAssertIdentical(engine.activeMatch, previousActive)
        XCTAssertFalse(previousActive.isLive)
        XCTAssertFalse(previousActive.isFinished)
        XCTAssertEqual(previousActive.durationMinutes, 130)
        XCTAssertEqual(previousActive.numberOfHalves, 4)
        XCTAssertEqual(previousActive.currentHalf, 4)
        XCTAssertEqual(previousActive.elapsedSeconds, 0)
        XCTAssertEqual(previousActive.homeScore, 0)
        XCTAssertEqual(previousActive.awayScore, 0)
        XCTAssertTrue(player.isStarter)
    }

    func testRestoreActiveMatchAfterFailedStartRestoresPreviousLiveState() {
        let previousActive = makeMatch()
        previousActive.isLive = true
        previousActive.isFinished = false
        let failedMatch = makeMatch()
        let engine = MatchEngine()
        engine.select(match: previousActive)
        engine.start(match: failedMatch)

        engine.restoreActiveMatchAfterFailedStart(
            failedMatchID: failedMatch.id,
            previousActiveMatch: previousActive,
            previousActiveWasLive: true
        )

        XCTAssertIdentical(engine.activeMatch, previousActive)
        XCTAssertTrue(previousActive.isLive)
        XCTAssertFalse(previousActive.isFinished)
    }

    func testRestoreActiveMatchAfterFailedStartDoesNotOverrideChangedActiveMatch() {
        let previousActive = makeMatch()
        let failedMatch = makeMatch()
        let newerActive = makeMatch()
        let engine = MatchEngine()
        engine.select(match: failedMatch)
        engine.select(match: newerActive)

        engine.restoreActiveMatchAfterFailedStart(
            failedMatchID: failedMatch.id,
            previousActiveMatch: previousActive
        )

        XCTAssertIdentical(engine.activeMatch, newerActive)
    }

    func testStartPromotesFallbackStarterWhenSideHasNoStarters() {
        let match = makeMatch()
        let homeLater = PlayerRecord(
            name: "Zulu",
            jerseyNumber: 30,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let homeFallback = PlayerRecord(
            name: "Alpha",
            jerseyNumber: 8,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let opponentStarter = PlayerRecord(
            name: "Opponent Starter",
            isStarter: true,
            teamSide: .opponent,
            match: match
        )
        match.players.append(contentsOf: [homeLater, homeFallback, opponentStarter])
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertFalse(homeLater.isStarter)
        XCTAssertTrue(homeFallback.isStarter)
        XCTAssertTrue(opponentStarter.isStarter)
    }

    func testStartFallbackStarterUsesSharedPlayerSelectionOrder() {
        let match = makeMatch()
        let forward = PlayerRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Same",
            jerseyNumber: 8,
            position: .forward,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let defender = PlayerRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            name: "Same",
            jerseyNumber: 8,
            position: .defender,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        match.players.append(contentsOf: [forward, defender])
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertFalse(forward.isStarter)
        XCTAssertTrue(defender.isStarter)
    }

    func testStartDoesNotPromoteInvalidRawSidePlayerAsFallbackStarter() {
        let match = makeMatch()
        let invalidSidePlayer = PlayerRecord(
            name: "Invalid Side",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        invalidSidePlayer.teamSideRawValue = "visitor"
        match.players.append(invalidSidePlayer)
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertFalse(invalidSidePlayer.isStarter)
    }

    func testLiveActivePlayerIDsAppliesSubstitutionsInTimelineOrder() {
        let match = makeMatch()
        let starter = PlayerRecord(
            name: "Starter",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let firstSub = PlayerRecord(
            name: "First Sub",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let secondSub = PlayerRecord(
            name: "Second Sub",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        match.players.append(contentsOf: [starter, firstSub, secondSub])

        let sharedTimestamp = Date(timeIntervalSince1970: 100)
        let laterSubstitution = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 20,
            period: .firstHalf,
            eventType: .substitution,
            playerID: firstSub.id,
            secondaryPlayerID: secondSub.id,
            match: match
        )
        let earlierSubstitution = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 10,
            period: .firstHalf,
            eventType: .substitution,
            playerID: starter.id,
            secondaryPlayerID: firstSub.id,
            match: match
        )
        match.events.append(contentsOf: [laterSubstitution, earlierSubstitution])

        XCTAssertEqual(match.liveActivePlayerIDs(for: .home), Set([secondSub.id]))
    }

    func testLiveActivePlayerIDsIgnoresMalformedSubstitutions() {
        let match = makeMatch()
        let starter = PlayerRecord(
            name: "Starter",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let benchPlayer = PlayerRecord(
            name: "Bench",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let otherBenchPlayer = PlayerRecord(
            name: "Other Bench",
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let legacyStarter = PlayerRecord(
            name: "Legacy Starter",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        legacyStarter.teamSideRawValue = "visitor"
        let opponentPlayer = PlayerRecord(
            name: "Opponent",
            isStarter: false,
            teamSide: .opponent,
            match: match
        )
        match.players.append(contentsOf: [starter, benchPlayer, otherBenchPlayer, legacyStarter, opponentPlayer])

        let missingPlayerOn = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: starter.id,
            match: match
        )
        let wrongSidePlayerOn = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 110),
            matchMinute: 11,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: starter.id,
            secondaryPlayerID: opponentPlayer.id,
            match: match
        )
        let inactivePlayerOff = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 120),
            matchMinute: 12,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: benchPlayer.id,
            secondaryPlayerID: otherBenchPlayer.id,
            match: match
        )
        let invalidPeriodSubstitution = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 130),
            matchMinute: 13,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: starter.id,
            secondaryPlayerID: benchPlayer.id,
            match: match
        )
        invalidPeriodSubstitution.periodRawValue = "futurePeriod"
        let invalidPlayerOffSideSubstitution = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 140),
            matchMinute: 14,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: legacyStarter.id,
            secondaryPlayerID: benchPlayer.id,
            match: match
        )
        match.events.append(contentsOf: [
            missingPlayerOn,
            wrongSidePlayerOn,
            inactivePlayerOff,
            invalidPeriodSubstitution,
            invalidPlayerOffSideSubstitution
        ])

        XCTAssertEqual(match.liveActivePlayerIDs(for: .home), Set([starter.id]))
    }

    func testLiveActivePlayerIDsIgnoresSubstitutionWhenPlayerOnIsAlreadyActive() {
        let match = makeMatch()
        let playerOff = PlayerRecord(
            name: "Player Off",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let alreadyActive = PlayerRecord(
            name: "Already Active",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        match.players.append(contentsOf: [playerOff, alreadyActive])

        let duplicateActiveSubstitution = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: playerOff.id,
            secondaryPlayerID: alreadyActive.id,
            match: match
        )
        match.events.append(duplicateActiveSubstitution)

        XCTAssertEqual(match.liveActivePlayerIDs(for: .home), Set([playerOff.id, alreadyActive.id]))
    }

    func testTimelineDetailTextShowsSubstitutionPlayerOffAndOn() {
        let match = makeMatch()
        let playerOff = PlayerRecord(name: "Player Off", teamSide: .home, match: match)
        let playerOn = PlayerRecord(name: "Player On", teamSide: .home, match: match)
        match.players.append(contentsOf: [playerOff, playerOn])
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .substitution,
            teamSide: .home,
            playerID: playerOff.id,
            secondaryPlayerID: playerOn.id,
            notes: "Fresh legs",
            match: match
        )

        XCTAssertEqual(match.timelineDetailText(for: event), "Player Off -> Player On • Fresh legs")
    }

    func testTimelineDetailTextUsesDisplayTitleForSourceOnlyEvents() {
        let match = makeMatch()
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .shotOnTarget,
            sourceDevice: .watch,
            match: match
        )

        XCTAssertEqual(match.timelineDetailText(for: event), "Watch")
    }

    func testTimelineDetailTextHidesInvalidSourceDeviceFallback() {
        let match = makeMatch()
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .shotOnTarget,
            sourceDevice: .watch,
            match: match
        )
        event.sourceDeviceRawValue = "legacy-device"

        XCTAssertNil(match.timelineDetailText(for: event))
    }

    func testTimelineDetailTextHidesDetailsForInvalidEventType() {
        let match = makeMatch()
        let player = PlayerRecord(name: "Finisher", teamSide: .home, match: match)
        match.players.append(player)
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .goal,
            playerID: player.id,
            notes: "Top corner",
            sourceDevice: .watch,
            match: match
        )
        event.eventTypeRawValue = "legacy-event"

        XCTAssertEqual(event.displayTitle, "Unknown Event")
        XCTAssertNil(match.timelineDetailText(for: event))
        XCTAssertEqual(match.summaryTimelineDetailText(for: event, scope: .both), "Midline FC")
    }

    func testTimelineDetailTextHidesDetailsForInvalidPeriod() {
        let match = makeMatch()
        let player = PlayerRecord(name: "Finisher", teamSide: .home, match: match)
        match.players.append(player)
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .goal,
            playerID: player.id,
            notes: "Top corner",
            sourceDevice: .watch,
            match: match
        )
        event.periodRawValue = "futurePeriod"

        XCTAssertNil(match.timelineDetailText(for: event))
        XCTAssertEqual(match.summaryTimelineDetailText(for: event, scope: .both), "Midline FC")
    }

    func testTimelineDetailTextHidesDetailsForInvalidTeamSide() {
        let match = makeMatch()
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .shotOnTarget,
            notes: "Saved",
            sourceDevice: .watch,
            match: match
        )
        event.teamSideRawValue = "visitor"

        XCTAssertNil(match.timelineDetailText(for: event))
        XCTAssertNil(match.summaryTimelineDetailText(for: event, scope: .both))
    }

    func testSummaryTimelineDetailTextPrefixesTeamForBothTeamsScope() {
        let match = makeMatch()
        match.teamName = "Midline FC"
        match.opponentName = "Rivals FC"
        let player = PlayerRecord(name: "Finisher", teamSide: .opponent, match: match)
        match.players.append(player)
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .opponent,
            playerID: player.id,
            match: match
        )

        XCTAssertEqual(match.summaryTimelineDetailText(for: event, scope: .both), "Rivals FC • Finisher")
        XCTAssertEqual(match.summaryTimelineDetailText(for: event, scope: .opponent), "Finisher")
    }

    func testSummaryTimelineDetailTextShowsTeamWhenBothTeamsEventHasNoDetail() {
        let match = makeMatch()
        match.teamName = "Midline FC"
        match.opponentName = "Rivals FC"
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .cornerWon,
            teamSide: .home,
            sourceDevice: .watch,
            match: match
        )
        event.sourceDeviceRawValue = "legacy-device"

        XCTAssertEqual(match.summaryTimelineDetailText(for: event, scope: .both), "Midline FC")
        XCTAssertNil(match.summaryTimelineDetailText(for: event, scope: .home))
    }

    func testSummaryTimelineEventsIgnoreInvalidRawRows() {
        let match = makeMatch()
        let validHomeEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 10,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            match: match
        )
        let validOpponentEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 101),
            matchMinute: 11,
            period: .firstHalf,
            eventType: .save,
            teamSide: .opponent,
            match: match
        )
        let invalidPeriodEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 102),
            matchMinute: 12,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidPeriodEvent.periodRawValue = "futurePeriod"
        let invalidTypeEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 103),
            matchMinute: 13,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidTypeEvent.eventTypeRawValue = "legacyEvent"
        let invalidTeamEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 104),
            matchMinute: 14,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidTeamEvent.teamSideRawValue = "visitor"
        match.events.append(contentsOf: [
            validOpponentEvent,
            invalidPeriodEvent,
            validHomeEvent,
            invalidTypeEvent,
            invalidTeamEvent
        ])

        XCTAssertEqual(match.summaryTimelineEvents(for: .home).map(\.id), [validHomeEvent.id])
        XCTAssertEqual(match.summaryTimelineEvents(for: .opponent).map(\.id), [validOpponentEvent.id])
        XCTAssertEqual(match.summaryTimelineEvents(for: .both).map(\.id), [validHomeEvent.id, validOpponentEvent.id])
    }

    func testTimelineSortsByMinuteThenTimestamp() {
        let match = makeMatch()
        let earlyInMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 12,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )
        let laterInSameMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 120),
            matchMinute: 12,
            period: .firstHalf,
            eventType: .goal,
            match: match
        )
        let earlierMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 140),
            matchMinute: 11,
            period: .firstHalf,
            eventType: .cornerWon,
            match: match
        )
        match.events.append(contentsOf: [laterInSameMinute, earlyInMinute, earlierMinute])

        XCTAssertEqual(match.events.sortedForTimeline().map(\.id), [
            earlierMinute.id,
            earlyInMinute.id,
            laterInSameMinute.id
        ])
    }

    func testTimelineSortsSameVisibleFieldsByStableID() throws {
        let match = makeMatch()
        let timestamp = Date(timeIntervalSince1970: 125)
        let higherIDEvent = MatchEventRecord(
            id: try XCTUnwrap(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
            timestamp: timestamp,
            matchMinute: 12,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )
        let lowerIDEvent = MatchEventRecord(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            timestamp: timestamp,
            matchMinute: 12,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )
        match.events.append(contentsOf: [higherIDEvent, lowerIDEvent])

        XCTAssertEqual(match.events.sortedForTimeline().map(\.id), [
            lowerIDEvent.id,
            higherIDEvent.id
        ])
        XCTAssertEqual(match.events.sortedForRecentTimeline().map(\.id), [
            lowerIDEvent.id,
            higherIDEvent.id
        ])
    }

    func testTimelineUsesClampedMinuteForLegacyInvalidRows() {
        let match = makeMatch()
        let invalidMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 150),
            matchMinute: 8,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )
        invalidMinute.matchMinute = -12
        let firstMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 140),
            matchMinute: 1,
            period: .firstHalf,
            eventType: .goal,
            match: match
        )
        let laterMinute = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 130),
            matchMinute: 2,
            period: .firstHalf,
            eventType: .cornerWon,
            match: match
        )
        match.events.append(contentsOf: [laterMinute, invalidMinute, firstMinute])

        XCTAssertEqual(invalidMinute.matchMinuteValue, 1)
        XCTAssertEqual(match.events.sortedForTimeline().map(\.id), [
            firstMinute.id,
            invalidMinute.id,
            laterMinute.id
        ])
        XCTAssertEqual(match.events.sortedForRecentTimeline().map(\.id), [
            laterMinute.id,
            invalidMinute.id,
            firstMinute.id
        ])
    }

    func testLoggedEventCapturesElapsedClockForTimelineDisplay() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.elapsedSeconds = 754
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .shotOnTarget,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.matchMinuteValue, 13)
        XCTAssertEqual(event.elapsedSeconds, 754)
        XCTAssertEqual(event.matchClockText, "12:34")
        XCTAssertEqual(match.summaryTimelineEvents(for: .home).first?.matchClockText, "12:34")
    }

    func testLegacyEventClockTextFallsBackToMatchMinute() {
        let match = makeMatch()
        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 150),
            matchMinute: 12,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )

        XCTAssertNil(event.elapsedSeconds)
        XCTAssertEqual(event.matchClockText, "12:00")
    }

    func testTimelineSortsLinkedGoalBeforeAssist() {
        let match = makeMatch()
        let timestamp = Date(timeIntervalSince1970: 160)
        let assist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 18,
            period: .firstHalf,
            eventType: .assist,
            match: match
        )
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 18,
            period: .firstHalf,
            eventType: .goal,
            match: match
        )
        match.events.append(contentsOf: [assist, goal])

        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.goal, .assist])
    }

    func testTimelineSortsCommittedFoulBeforeWonFoul() {
        let match = makeMatch()
        let timestamp = Date(timeIntervalSince1970: 170)
        let won = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 22,
            period: .firstHalf,
            eventType: .foulWon,
            match: match
        )
        let committed = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 22,
            period: .firstHalf,
            eventType: .foulCommitted,
            match: match
        )
        match.events.append(contentsOf: [won, committed])

        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.foulCommitted, .foulWon])
    }

    func testRecentTimelineSortsNewestEventsFirst() {
        let match = makeMatch()
        let older = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 180),
            matchMinute: 23,
            period: .firstHalf,
            eventType: .cornerWon,
            match: match
        )
        let newer = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 190),
            matchMinute: 24,
            period: .firstHalf,
            eventType: .shotOnTarget,
            match: match
        )
        match.events.append(contentsOf: [older, newer])

        XCTAssertEqual(match.events.sortedForRecentTimeline().map(\.eventType), [.shotOnTarget, .cornerWon])
    }

    func testRecentTimelineKeepsLinkedGoalBeforeAssist() {
        let match = makeMatch()
        let older = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 200),
            matchMinute: 25,
            period: .firstHalf,
            eventType: .cornerWon,
            match: match
        )
        let timestamp = Date(timeIntervalSince1970: 210)
        let assist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 26,
            period: .firstHalf,
            eventType: .assist,
            match: match
        )
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 26,
            period: .firstHalf,
            eventType: .goal,
            match: match
        )
        match.events.append(contentsOf: [older, assist, goal])

        XCTAssertEqual(match.events.sortedForRecentTimeline().map(\.eventType), [.goal, .assist, .cornerWon])
    }

    func testMatchSearchIncludesDateAndTeamFields() {
        let match = MatchRecord(
            title: "Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            date: Date(timeIntervalSince1970: 1_767_139_200)
        )
        let dateQuery = match.date.formatted(date: .abbreviated, time: .omitted)
        let numericDateQuery = match.date.formatted(date: .numeric, time: .omitted)

        XCTAssertTrue(match.matchesSearchQuery(""))
        XCTAssertTrue(match.matchesSearchQuery(" - / "))
        XCTAssertTrue(match.matchesSearchQuery("midline"))
        XCTAssertTrue(match.matchesSearchQuery(dateQuery))
        XCTAssertTrue(match.matchesSearchQuery(numericDateQuery))
        XCTAssertFalse(match.matchesSearchQuery("training"))
    }

    func testDuplicateSetupDraftPreservesCustomTitleAndMatchFormat() {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            date: Date(timeIntervalSince1970: 100),
            durationMinutes: 75,
            numberOfHalves: 4,
            isQuickMatch: true,
            accent: .sunsetOrange,
            trackedEventTypes: [.goal, .yellowCard]
        )

        let draft = MatchSetupDraft.duplicate(from: match, date: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(draft.title, "Cup Final")
        XCTAssertEqual(draft.teamName, "Midline FC")
        XCTAssertEqual(draft.opponentName, "Rivals FC")
        XCTAssertEqual(draft.date, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(draft.durationMinutes, 75)
        XCTAssertEqual(draft.numberOfHalves, 4)
        XCTAssertTrue(draft.extraTimeEnabled)
        XCTAssertEqual(draft.extraTimeHalfDurationMinutes, 15)
        XCTAssertTrue(draft.isQuickMatch)
        XCTAssertEqual(draft.accent, .sunsetOrange)
        XCTAssertEqual(draft.trackedEventTypes, [.goal, .yellowCard])
    }

    func testDuplicateSetupDraftExportsDisplaySafeRosterBySideAndStarterStatus() {
        let match = makeMatch()
        let starterWithJersey = PlayerRecord(
            name: "A Starter",
            jerseyNumber: 9,
            position: .forward,
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let starterWithoutJersey = PlayerRecord(
            name: "B Starter",
            position: .midfielder,
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let benchPlayer = PlayerRecord(
            name: "Bench",
            jerseyNumber: 12,
            position: .defender,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        let opponentStarter = PlayerRecord(
            name: "Opponent",
            jerseyNumber: 4,
            position: .goalkeeper,
            isStarter: true,
            teamSide: .opponent,
            match: match
        )
        let invalidSidePlayer = PlayerRecord(name: "Legacy", teamSide: .home, match: match)
        invalidSidePlayer.teamSideRawValue = "visitor"
        match.players.append(contentsOf: [
            starterWithoutJersey,
            benchPlayer,
            opponentStarter,
            invalidSidePlayer,
            starterWithJersey
        ])

        let draft = MatchSetupDraft.duplicate(from: match)

        XCTAssertEqual(draft.homeStartingPlayersText, "A Starter,#9,forward\nB Starter,,midfielder")
        XCTAssertEqual(draft.homeBenchPlayersText, "Bench,#12,defender")
        XCTAssertEqual(draft.opponentStartingPlayersText, "Opponent,#4,goalkeeper")
        XCTAssertEqual(draft.opponentBenchPlayersText, "")
        XCTAssertTrue(draft.hasPlayers)
    }

    func testDuplicateSetupDraftRosterTiesUsePositionOrderBeforeStableID() {
        let match = makeMatch()
        let forward = PlayerRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            name: "Same Name",
            jerseyNumber: 8,
            position: .forward,
            isStarter: true,
            teamSide: .home,
            match: match
        )
        let defender = PlayerRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Same Name",
            jerseyNumber: 8,
            position: .defender,
            isStarter: true,
            teamSide: .home,
            match: match
        )
        match.players.append(contentsOf: [forward, defender])

        let draft = MatchSetupDraft.duplicate(from: match)

        XCTAssertEqual(draft.homeStartingPlayersText, "Same Name,#8,defender\nSame Name,#8,forward")
    }

    func testDuplicateSetupDraftKeepsEachPlayerOnOneLine() {
        let match = makeMatch()
        let legacyPlayer = PlayerRecord(
            name: "Line\nBreak",
            isStarter: true,
            teamSide: .home,
            match: match
        )
        match.players.append(legacyPlayer)

        let draft = MatchSetupDraft.duplicate(from: match)

        XCTAssertEqual(draft.homeStartingPlayersText, "Line Break,,utility")
    }

    func testDuplicateSetupDraftQuotesRosterNamesThatNeedEscaping() {
        let match = makeMatch()
        let player = PlayerRecord(
            name: "Ali \"Ace\", Jr.",
            jerseyNumber: 7,
            position: .forward,
            isStarter: true,
            teamSide: .home,
            match: match
        )
        match.players.append(player)

        let draft = MatchSetupDraft.duplicate(from: match)
        let parsedPlayer = MatchSetupPlayerLineParser.parse(draft.homeStartingPlayersText)

        XCTAssertEqual(draft.homeStartingPlayersText, "\"Ali \"\"Ace\"\", Jr.\",#7,forward")
        XCTAssertEqual(parsedPlayer?.name, "Ali \"Ace\", Jr.")
        XCTAssertEqual(parsedPlayer?.jerseyNumberText, "7")
        XCTAssertEqual(parsedPlayer?.position, .forward)
    }

    func testSetupDraftDoesNotTreatWhitespaceRosterTextAsPlayers() {
        let draft = MatchSetupDraft(
            title: "Whitespace",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            durationMinutes: 90,
            numberOfHalves: 2,
            isQuickMatch: false,
            accent: .stadiumGreen,
            trackedEventTypes: [.goal],
            homeStartingPlayersText: " \n\t",
            homeBenchPlayersText: "",
            opponentStartingPlayersText: "   ",
            opponentBenchPlayersText: "\n"
        )

        XCTAssertFalse(draft.hasPlayers)
    }

    func testSetupDraftDoesNotTreatDelimiterOnlyRosterTextAsPlayers() {
        let draft = MatchSetupDraft(
            title: "Malformed",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            durationMinutes: 90,
            numberOfHalves: 2,
            isQuickMatch: false,
            accent: .stadiumGreen,
            trackedEventTypes: [.goal],
            homeStartingPlayersText: ",,midfielder\n,#9,forward",
            homeBenchPlayersText: " , , ",
            opponentStartingPlayersText: "",
            opponentBenchPlayersText: "\n,,"
        )

        XCTAssertFalse(draft.hasPlayers)
    }

    func testSetupDraftDoesNotTreatRosterHeaderRowsAsPlayers() {
        let draft = MatchSetupDraft(
            title: "Headers",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            durationMinutes: 90,
            numberOfHalves: 2,
            isQuickMatch: false,
            accent: .stadiumGreen,
            trackedEventTypes: [.goal],
            homeStartingPlayersText: "Name,Jersey,Position\nJersey,Name,Position",
            homeBenchPlayersText: "Player,#,Pos\n#,Player,Pos",
            opponentStartingPlayersText: "Player Name,No,Position\nNo,Player Name,Position",
            opponentBenchPlayersText: ""
        )

        XCTAssertFalse(draft.hasPlayers)
    }

    func testSetupPlayerNameValidationRejectsSymbolOnlyText() {
        XCTAssertFalse(MatchSetupPlayerLineParser.containsNameText(""))
        XCTAssertFalse(MatchSetupPlayerLineParser.containsNameText(" , # "))
        XCTAssertFalse(MatchSetupPlayerLineParser.containsNameText("---"))
        XCTAssertTrue(MatchSetupPlayerLineParser.containsNameText("Player 9"))
        XCTAssertTrue(MatchSetupPlayerLineParser.containsNameText("لاعب"))
    }

    func testSetupPlayerDraftParserPreservesPositionWithoutJersey() {
        let drafts = [
            "A Starter,#9,forward",
            "B Starter,,midfielder",
            "Legacy Starter,defender"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["A Starter", "B Starter", "Legacy Starter"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["9", "", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .defender])
    }

    func testSetupPlayerDraftParserSkipsHeaderRows() {
        let drafts = MatchSetupPlayerLineParser.parseLines(
            in: "Name,Jersey,Position\nA Starter,#9,forward\nJersey,Name,Position\nNo,Player Name,Pos\nPlayer,#7,midfielder"
        )

        XCTAssertEqual(drafts.map(\.name), ["A Starter", "Player"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["9", "7"])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder])
    }

    func testSetupPlayerDraftParserIgnoresTrailingEmptyFields() {
        let drafts = [
            "A Starter,#9,forward,",
            "B Starter,,midfielder, ",
            "Legacy Starter,defender,,"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["A Starter", "B Starter", "Legacy Starter"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["9", "", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .defender])
    }

    func testSetupPlayerDraftParserKeepsPositionWordsAsSingleFieldNames() {
        let drafts = [
            "Forward",
            "Midfielder",
            "Legacy Starter,defender"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["Forward", "Midfielder", "Legacy Starter"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["", "", ""])
        XCTAssertEqual(drafts.map(\.position), [.utility, .utility, .defender])
    }

    func testSetupPlayerDraftParserPreservesCommaNames() {
        let drafts = [
            "Doe, John,#9,forward",
            "Smith, Jane,midfielder",
            "Bench, Utility,,utility"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["Doe, John", "Smith, Jane", "Bench, Utility"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["9", "", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .utility])
    }

    func testSetupPlayerDraftParserUnescapesQuotedNames() {
        let drafts = [
            "\"Ali \"\"Ace\"\", Jr.\",#7,forward",
            "  \"Smith, Jane\"  ,midfielder"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["Ali \"Ace\", Jr.", "Smith, Jane"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["7", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder])
    }

    func testSetupPlayerDraftParserKeepsDigitsInsideNames() {
        let drafts = [
            "Area 51,forward",
            "Player 2,#10,midfielder",
            "Player 12,12,defender"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["Area 51", "Player 2", "Player 12"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["", "10", "12"])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .defender])
    }

    func testSetupPlayerDraftParserCollapsesNameWhitespace() {
        let drafts = [
            "  Line\tBreak,#8,forward",
            "  Multi   Space  Name  ,midfielder"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["Line Break", "Multi Space Name"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["8", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder])
    }

    func testSetupPlayerDraftParserSplitsAllNewlineStyles() {
        let drafts = MatchSetupPlayerLineParser.parseLines(
            in: "First,#1,forward\rSecond,#2,midfielder\r\nThird,#3,defender\nFourth,#4,goalkeeper"
        )

        XCTAssertEqual(drafts.map(\.name), ["First", "Second", "Third", "Fourth"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["1", "2", "3", "4"])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .defender, .goalkeeper])
    }

    func testSetupPlayerDraftParserNormalizesUnicodeJerseyDigits() {
        let drafts = MatchSetupPlayerLineParser.parseLines(in: "Yasir,#١٢,forward\nSami,٣٤,midfielder\nIcon,⑩,defender")

        XCTAssertEqual(drafts.map(\.name), ["Yasir", "Sami", "Icon,⑩"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["12", "34", ""])
        XCTAssertEqual(MatchFormat.sanitizedJerseyNumberText("#١٢٣٤⑩"), "123")
        XCTAssertEqual(MatchFormat.jerseyNumber(fromText: "#١٢٣٤⑩"), 123)
    }

    func testSetupPlayerDraftParserKeepsHashPrefixedNames() {
        let drafts = [
            "#Captain,forward",
            "#10 Starter,#9,midfielder",
            "Hash Placeholder,#,utility",
            "#10,defender"
        ].compactMap(MatchSetupPlayerLineParser.parse)

        XCTAssertEqual(drafts.map(\.name), ["#Captain", "#10 Starter", "Hash Placeholder"])
        XCTAssertEqual(drafts.map(\.jerseyNumberText), ["", "9", ""])
        XCTAssertEqual(drafts.map(\.position), [.forward, .midfielder, .utility])
    }

    func testMatchRecordSanitizesBlankDisplayNames() {
        let match = MatchRecord(
            title: " \n ",
            teamName: "  ",
            opponentName: "\t"
        )

        XCTAssertEqual(match.title, "Home vs Opponent")
        XCTAssertEqual(match.teamName, "Home")
        XCTAssertEqual(match.opponentName, "Opponent")
        XCTAssertEqual(match.displayTitle, "Home vs Opponent")
        XCTAssertEqual(match.displayTeamName, "Home")
        XCTAssertEqual(match.displayOpponentName, "Opponent")
        XCTAssertTrue(match.matchesSearchQuery("opponent"))
    }

    func testMatchRecordSanitizesSymbolOnlyDisplayNames() {
        let match = MatchRecord(
            title: " --- ",
            teamName: " , # ",
            opponentName: "!!!"
        )

        XCTAssertEqual(match.title, "Home vs Opponent")
        XCTAssertEqual(match.teamName, "Home")
        XCTAssertEqual(match.opponentName, "Opponent")
        XCTAssertEqual(match.displayTitle, "Home vs Opponent")
        XCTAssertEqual(match.displayTeamName, "Home")
        XCTAssertEqual(match.displayOpponentName, "Opponent")

        match.title = " - "
        match.teamName = "..."
        match.opponentName = "///"

        XCTAssertEqual(match.displayTitle, "Home vs Opponent")
        XCTAssertEqual(match.displayTeamName, "Home")
        XCTAssertEqual(match.displayOpponentName, "Opponent")
    }

    func testMatchRecordDisplayNamesCollapseLineBreaks() {
        let match = MatchRecord(
            title: "  Derby\nNight\tFinal  ",
            teamName: "  Midline\nFC  ",
            opponentName: "  Rival\tClub  "
        )

        XCTAssertEqual(match.title, "Derby Night Final")
        XCTAssertEqual(match.teamName, "Midline FC")
        XCTAssertEqual(match.opponentName, "Rival Club")

        match.title = "  Legacy\nTitle  "
        match.teamName = "  Legacy\nHome  "
        match.opponentName = "  Legacy\tOpponent  "

        XCTAssertEqual(match.displayTitle, "Legacy Title")
        XCTAssertEqual(match.displayTeamName, "Legacy Home")
        XCTAssertEqual(match.displayOpponentName, "Legacy Opponent")
        XCTAssertTrue(match.matchesSearchQuery("legacy opponent"))
        XCTAssertTrue(match.matchesSearchQuery("legacy\nopponent"))
    }

    func testMatchRecordFinishedInitializerIsNotLive() {
        let match = MatchRecord(
            title: "Final",
            teamName: "Home",
            opponentName: "Opponent",
            isLive: true,
            isFinished: true
        )

        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testLegacyBlankDisplayNamesUseFallbacksInAnalytics() {
        let match = makeMatch()
        match.title = " "
        match.teamName = "\n"
        match.opponentName = "\t"
        let player = PlayerRecord(name: "Player", teamSide: .home, match: match)
        player.name = "  "
        let event = MatchEventRecord(
            matchMinute: 9,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            playerID: player.id,
            match: match
        )
        match.players.append(player)
        match.events.append(event)

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(match.displayTitle, "Home vs Opponent")
        XCTAssertEqual(summary.scoreLine, "Home 0 - 0 Opponent")
        XCTAssertEqual(summary.mostActivePlayer?.playerName, "Unknown Player")
    }

    func testPlayerRecordSanitizesSymbolOnlyNames() {
        let player = PlayerRecord(name: "---")

        XCTAssertEqual(player.name, "Unknown Player")

        player.name = " , # "
        XCTAssertEqual(player.displayName, "Unknown Player")
    }

    func testPlayerRecordSanitizesJerseyNumbers() {
        let validPlayer = PlayerRecord(name: "Winger", jerseyNumber: 999)
        let negativePlayer = PlayerRecord(name: "Defender", jerseyNumber: -1)
        let longPlayer = PlayerRecord(name: "Keeper", jerseyNumber: 1000)

        XCTAssertEqual(validPlayer.jerseyNumber, 999)
        XCTAssertEqual(validPlayer.jerseyNumberValue, 999)
        XCTAssertNil(negativePlayer.jerseyNumber)
        XCTAssertNil(negativePlayer.jerseyNumberValue)
        XCTAssertNil(longPlayer.jerseyNumber)
        XCTAssertNil(longPlayer.jerseyNumberValue)
    }

    func testPlayerRecordDisplayNameCollapsesLineBreaks() {
        let player = PlayerRecord(name: "  First\nLast\tName  ")

        XCTAssertEqual(player.name, "First Last Name")

        player.name = "  Legacy\nPlayer\tName  "

        XCTAssertEqual(player.displayName, "Legacy Player Name")
    }

    func testLegacyInvalidJerseyNumbersAreHiddenFromDisplayValue() {
        let player = PlayerRecord(name: "Legacy", jerseyNumber: 7)

        player.jerseyNumber = -5
        XCTAssertNil(player.jerseyNumberValue)

        player.jerseyNumber = 1000
        XCTAssertNil(player.jerseyNumberValue)

        player.jerseyNumber = 10
        XCTAssertEqual(player.jerseyNumberValue, 10)
    }

    func testPlayerSelectionSortsByJerseyNamePositionAndStableID() {
        let noJersey = PlayerRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "No Jersey",
            position: .forward
        )
        let laterSameVisiblePlayer = PlayerRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            name: "Same",
            jerseyNumber: 8,
            position: .midfielder
        )
        let earlierSameVisiblePlayer = PlayerRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Same",
            jerseyNumber: 8,
            position: .midfielder
        )
        let defender = PlayerRecord(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "Same",
            jerseyNumber: 8,
            position: .defender
        )
        let lowerJersey = PlayerRecord(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            name: "Lower",
            jerseyNumber: 3,
            position: .utility
        )
        let legacyInvalidJersey = PlayerRecord(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            name: "Legacy",
            jerseyNumber: 7,
            position: .goalkeeper
        )
        legacyInvalidJersey.jerseyNumber = 1000

        let sortedPlayers = [
            noJersey,
            laterSameVisiblePlayer,
            earlierSameVisiblePlayer,
            defender,
            lowerJersey,
            legacyInvalidJersey
        ].sortedForPlayerSelection()

        XCTAssertEqual(sortedPlayers.map(\.id), [
            lowerJersey.id,
            defender.id,
            earlierSameVisiblePlayer.id,
            laterSameVisiblePlayer.id,
            legacyInvalidJersey.id,
            noJersey.id
        ])
    }

    func testMatchCurrentHalfLabelsUseActualHalfNumber() {
        let match = makeMatch()

        match.currentHalf = 1
        XCTAssertEqual(match.currentHalfTitle, "1st Half")
        XCTAssertEqual(match.currentHalfShortTitle, "H1")

        match.currentHalf = 2
        XCTAssertEqual(match.currentHalfTitle, "2nd Half")
        XCTAssertEqual(match.currentHalfShortTitle, "H2")

        match.numberOfHalves = 4
        match.currentHalf = 3
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 1")
        XCTAssertEqual(match.currentHalfShortTitle, "ET1")

        match.currentHalf = 4
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 2")
        XCTAssertEqual(match.currentHalfShortTitle, "ET2")
    }

    func testMatchCurrentHalfClampsToAvailablePeriods() {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            numberOfHalves: 2,
            currentHalf: 99
        )

        XCTAssertEqual(match.currentHalf, 2)
        XCTAssertEqual(match.currentPeriodNumber, 2)
        XCTAssertEqual(match.currentHalfTitle, "2nd Half")
        XCTAssertEqual(match.currentHalfShortTitle, "H2")

        match.currentHalf = 99
        XCTAssertEqual(match.currentPeriodNumber, 2)
        XCTAssertEqual(match.currentHalfTitle, "2nd Half")

        match.numberOfHalves = 4
        XCTAssertEqual(match.currentPeriodNumber, 4)
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 2")
        XCTAssertEqual(match.currentHalfShortTitle, "ET2")

        match.numberOfHalves = 99
        XCTAssertEqual(match.totalPeriodNumber, 4)
        XCTAssertEqual(match.currentPeriodNumber, 4)
    }

    func testMatchElapsedSecondsClampToClockRange() {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            elapsedSeconds: -12
        )

        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.elapsedClockSeconds, 0)
        XCTAssertEqual(MatchFormat.clampedElapsedSeconds(-1), 0)
        XCTAssertEqual(MatchFormat.clockText(forElapsedSeconds: -5), "00:00")
        XCTAssertEqual(MatchFormat.clockText(forElapsedSeconds: 615), "10:15")

        match.elapsedSeconds = -30
        XCTAssertEqual(match.elapsedClockSeconds, 0)
    }

    func testMatchScoresClampToScoreRange() {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            homeScore: -2,
            awayScore: -4
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(MatchFormat.clampedScore(-1), 0)

        match.homeScore = -8
        match.awayScore = -9
        XCTAssertEqual(match.homeScoreValue, 0)
        XCTAssertEqual(match.awayScoreValue, 0)
    }

    func testPersistedEnumRawValuesTrimWhitespace() throws {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC"
        )
        match.accentRawValue = " \(AppThemeAccent.matchBlue.rawValue)\n"

        let player = PlayerRecord(name: "Winger", teamSide: .home, match: match)
        player.positionRawValue = "\t\(PlayerPosition.forward.rawValue) "
        player.teamSideRawValue = " \(TeamSide.opponent.rawValue)\n"

        let event = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 100),
            matchMinute: 8,
            period: .firstHalf,
            eventType: .goal,
            match: match
        )
        event.periodRawValue = "\n\(MatchPeriod.secondHalf.rawValue) "
        event.eventTypeRawValue = " \(MatchEventType.yellowCard.rawValue)\t"
        event.teamSideRawValue = "\t\(TeamSide.opponent.rawValue)"
        event.sourceDeviceRawValue = "\n\(SourceDevice.watch.rawValue) "

        let settings = AppSettingsRecord()
        settings.themeAccentRawValue = "\t\(AppThemeAccent.sunsetOrange.rawValue) "
        settings.normalizePersistedValues()

        let configData = try XCTUnwrap("""
        {
            "playerTrackingMode": " \(PlayerTrackingMode.required.rawValue)\\n"
        }
        """.data(using: .utf8))
        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: configData)

        XCTAssertEqual(match.accent, .matchBlue)
        XCTAssertEqual(player.position, .forward)
        XCTAssertEqual(player.teamSide, .opponent)
        XCTAssertEqual(player.validTeamSide, .opponent)
        XCTAssertEqual(event.validPeriod, .secondHalf)
        XCTAssertEqual(event.validEventType, .yellowCard)
        XCTAssertEqual(event.validTeamSide, .opponent)
        XCTAssertEqual(event.validSourceDevice, .watch)
        XCTAssertTrue(event.hasValidRawValues)
        XCTAssertEqual(settings.themeAccentRawValue, AppThemeAccent.sunsetOrange.rawValue)
        XCTAssertEqual(config.playerTrackingMode, .required)
    }

    func testMatchDurationClampsToSupportedRange() {
        let shortMatch = MatchRecord(
            title: "Short",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            durationMinutes: -12
        )
        let longMatch = MatchRecord(
            title: "Long",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            durationMinutes: 999
        )
        let settings = AppSettingsRecord(defaultDurationMinutes: 999)

        XCTAssertEqual(shortMatch.durationMinutes, 1)
        XCTAssertEqual(longMatch.durationMinutes, 130)
        XCTAssertEqual(settings.defaultDurationMinutes, 130)
        XCTAssertEqual(MatchFormat.clampedDurationMinutes(-1), 1)
        XCTAssertEqual(MatchFormat.clampedDurationMinutes(999), 130)

        shortMatch.durationMinutes = -30
        settings.defaultDurationMinutes = -20
        XCTAssertEqual(shortMatch.durationMinuteValue, 1)
        XCTAssertEqual(settings.defaultDurationMinuteValue, 1)
    }

    func testMatchFormatClampsNumberOfPeriods() {
        XCTAssertEqual(MatchFormat.clampedNumberOfPeriods(0), 1)
        XCTAssertEqual(MatchFormat.clampedNumberOfPeriods(2), 2)
        XCTAssertEqual(MatchFormat.clampedNumberOfPeriods(99), 4)
        XCTAssertEqual(MatchFormat.clampedCurrentPeriod(99, numberOfPeriods: 2), 2)
        XCTAssertEqual(MatchFormat.clampedCurrentPeriod(0, numberOfPeriods: 4), 1)

        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            numberOfHalves: 99
        )
        XCTAssertEqual(match.numberOfHalves, 4)

        let settings = AppSettingsRecord(defaultNumberOfHalves: 99)
        XCTAssertEqual(settings.defaultNumberOfHalves, 4)

        settings.defaultNumberOfHalves = 99
        XCTAssertEqual(settings.defaultNumberOfHalvesValue, 4)

        settings.defaultNumberOfHalves = 0
        XCTAssertEqual(settings.defaultNumberOfHalvesValue, 1)
    }

    func testExtraTimeDefaultsAndClampsDuration() {
        let regularMatch = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC"
        )
        let extraTimeMatch = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            extraTimeEnabled: true,
            extraTimeHalfDurationMinutes: 99
        )
        let legacyExtraTimeMatch = MatchRecord(
            title: "Legacy Cup",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            numberOfHalves: 4
        )

        XCTAssertFalse(regularMatch.usesExtraTime)
        XCTAssertEqual(regularMatch.totalPeriodNumber, 2)
        XCTAssertEqual(regularMatch.extraTimeHalfDurationMinuteValue, 15)
        XCTAssertEqual(regularMatch.formatSummaryText, "90 min regulation")

        XCTAssertTrue(extraTimeMatch.usesExtraTime)
        XCTAssertEqual(extraTimeMatch.numberOfHalves, 4)
        XCTAssertEqual(extraTimeMatch.totalPeriodNumber, 4)
        XCTAssertEqual(extraTimeMatch.extraTimeHalfDurationMinuteValue, 45)
        XCTAssertEqual(extraTimeMatch.formatSummaryText, "90 min + ET 45 min halves")

        XCTAssertTrue(legacyExtraTimeMatch.usesExtraTime)
        XCTAssertEqual(legacyExtraTimeMatch.extraTimeHalfDurationMinuteValue, 15)
    }

    func testExtraTimeSettingsNormalizeLegacyPeriodDefaults() {
        let settings = AppSettingsRecord(defaultNumberOfHalves: 4, defaultExtraTimeHalfDurationMinutes: 0)

        settings.normalizePersistedValues()

        XCTAssertTrue(settings.defaultUsesExtraTime)
        XCTAssertEqual(settings.defaultNumberOfHalves, 4)
        XCTAssertEqual(settings.defaultExtraTimeHalfDurationMinuteValue, 1)
    }

    func testMatchRecordMigrationNilFootballFieldsUseSafeDefaults() {
        let match = makeMatch()
        match.extraTimeEnabled = nil
        match.extraTimeHalfDurationMinutes = nil
        match.shootoutStatusRawValue = nil
        match.homePenaltyScore = nil
        match.awayPenaltyScore = nil
        match.substitutionLimitModeRawValue = nil
        match.substitutionLimit = nil
        match.trackedEventTypeRawValues = nil

        XCTAssertFalse(match.usesExtraTime)
        XCTAssertEqual(match.totalPeriodNumber, 2)
        XCTAssertEqual(match.extraTimeHalfDurationMinuteValue, 15)
        XCTAssertEqual(match.shootoutStatus, .notStarted)
        XCTAssertEqual(match.homePenaltyScoreValue, 0)
        XCTAssertEqual(match.awayPenaltyScoreValue, 0)
        XCTAssertTrue(match.substitutionsAreUnlimited)
        XCTAssertEqual(match.substitutionLimitValue, 5)
        XCTAssertEqual(match.trackedEventTypes, MatchEventType.defaultQuickActions)

        match.normalizePersistedValues()

        XCTAssertEqual(match.extraTimeEnabled, false)
        XCTAssertEqual(match.extraTimeHalfDurationMinutes, 15)
        XCTAssertEqual(match.shootoutStatusRawValue, PenaltyShootoutStatus.notStarted.rawValue)
        XCTAssertEqual(match.homePenaltyScore, 0)
        XCTAssertEqual(match.awayPenaltyScore, 0)
        XCTAssertEqual(match.substitutionLimitModeRawValue, SubstitutionLimitMode.unlimited.rawValue)
        XCTAssertEqual(match.substitutionLimit, 5)
        XCTAssertEqual(match.trackedEventTypeRawValues, MatchEventType.defaultQuickActions.map(\.rawValue))
    }

    func testAppSettingsMigrationNilFootballDefaultsUseSafeDefaults() {
        let settings = AppSettingsRecord()
        settings.defaultExtraTimeEnabled = nil
        settings.defaultExtraTimeHalfDurationMinutes = nil
        settings.defaultSubstitutionLimitModeRawValue = nil
        settings.defaultSubstitutionLimit = nil

        XCTAssertFalse(settings.defaultUsesExtraTime)
        XCTAssertEqual(settings.defaultTotalPeriodNumber, 2)
        XCTAssertEqual(settings.defaultExtraTimeHalfDurationMinuteValue, 15)
        XCTAssertEqual(settings.defaultSubstitutionLimitMode, .unlimited)
        XCTAssertEqual(settings.defaultSubstitutionLimitValue, 5)

        settings.normalizePersistedValues()

        XCTAssertEqual(settings.defaultExtraTimeEnabled, false)
        XCTAssertEqual(settings.defaultExtraTimeHalfDurationMinutes, 15)
        XCTAssertEqual(settings.defaultSubstitutionLimitModeRawValue, SubstitutionLimitMode.unlimited.rawValue)
        XCTAssertEqual(settings.defaultSubstitutionLimit, 5)
    }

    func testPrepareRequiredRecordsNormalizesMigrationNilFootballFields() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.mainContext
        let match = makeMatch()
        match.numberOfHalves = 4
        match.extraTimeEnabled = nil
        match.extraTimeHalfDurationMinutes = nil
        match.shootoutStatusRawValue = nil
        match.homePenaltyScore = nil
        match.awayPenaltyScore = nil
        match.substitutionLimitModeRawValue = nil
        match.substitutionLimit = nil
        match.trackedEventTypeRawValues = nil
        let event = MatchEventRecord(
            matchMinute: 12,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            match: match
        )
        event.sourceDeviceRawValue = nil
        match.events.append(event)
        let settings = AppSettingsRecord()
        settings.defaultExtraTimeEnabled = nil
        settings.defaultExtraTimeHalfDurationMinutes = nil
        settings.defaultSubstitutionLimitModeRawValue = nil
        settings.defaultSubstitutionLimit = nil
        context.insert(match)
        context.insert(event)
        context.insert(settings)
        try context.save()

        try persistence.prepareRequiredRecords(context: context)

        let storedMatch = try XCTUnwrap(context.fetch(FetchDescriptor<MatchRecord>()).first)
        XCTAssertEqual(storedMatch.extraTimeEnabled, true)
        XCTAssertEqual(storedMatch.numberOfHalves, 4)
        XCTAssertEqual(storedMatch.extraTimeHalfDurationMinutes, 15)
        XCTAssertEqual(storedMatch.shootoutStatusRawValue, PenaltyShootoutStatus.notStarted.rawValue)
        XCTAssertEqual(storedMatch.homePenaltyScore, 0)
        XCTAssertEqual(storedMatch.awayPenaltyScore, 0)
        XCTAssertEqual(storedMatch.substitutionLimitModeRawValue, SubstitutionLimitMode.unlimited.rawValue)
        XCTAssertEqual(storedMatch.substitutionLimit, 5)
        XCTAssertEqual(storedMatch.trackedEventTypeRawValues, MatchEventType.defaultQuickActions.map(\.rawValue))
        let storedEvent = try XCTUnwrap(storedMatch.events.first)
        XCTAssertEqual(storedEvent.sourceDevice, .iPhone)
        XCTAssertEqual(storedEvent.sourceDeviceRawValue, SourceDevice.iPhone.rawValue)
        XCTAssertEqual(storedEvent.validSourceDevice, .iPhone)

        let storedSettings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(storedSettings.defaultExtraTimeEnabled, false)
        XCTAssertEqual(storedSettings.defaultExtraTimeHalfDurationMinutes, 15)
        XCTAssertEqual(storedSettings.defaultSubstitutionLimitModeRawValue, SubstitutionLimitMode.unlimited.rawValue)
        XCTAssertEqual(storedSettings.defaultSubstitutionLimit, 5)
    }

    func testPersistenceRecoveryImportsLegacySQLiteStore() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("midline-legacy-\(UUID().uuidString).store")
        try createLegacySQLiteStore(at: storeURL)
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            let recoveredURL = storeURL.deletingLastPathComponent().appendingPathComponent("MidlineRecovered.store")
            try? FileManager.default.removeItem(at: recoveredURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: recoveredURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: recoveredURL.path + "-wal"))
        }

        let recoveredContainer = try XCTUnwrap(PersistenceController.recoverStoreForTesting(sourceURL: storeURL))
        let context = ModelContext(recoveredContainer)

        let matches = try context.fetch(FetchDescriptor<MatchRecord>())
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.displayTitle, "Legacy Final")
        XCTAssertEqual(match.displayTeamName, "Legacy FC")
        XCTAssertEqual(match.displayOpponentName, "Old Rivals")
        XCTAssertEqual(match.homeScore, 2)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.trackedEventTypes, MatchEventType.defaultQuickActions)
        XCTAssertEqual(match.events.count, 1)

        let event = try XCTUnwrap(match.events.first)
        XCTAssertEqual(event.eventType, .goal)
        XCTAssertEqual(event.sourceDevice, .iPhone)

        let settings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(settings.defaultDurationMinutes, 80)
        XCTAssertEqual(settings.defaultNumberOfHalves, 2)
    }

    func testThemeAccentTitlesUseReadableWords() {
        XCTAssertEqual(AppThemeAccent.stadiumGreen.title, "Stadium Green")
        XCTAssertEqual(AppThemeAccent.matchBlue.title, "Match Blue")
        XCTAssertEqual(AppThemeAccent.sunsetOrange.title, "Sunset Orange")
    }

    func testPlayerTrackingModeTitlesUseReadableWords() {
        XCTAssertEqual(PlayerTrackingMode.off.title, "Off")
        XCTAssertEqual(PlayerTrackingMode.optional.title, "Optional")
        XCTAssertEqual(PlayerTrackingMode.required.title, "Required")
    }

    func testPrepareRequiredRecordsCreatesSettingsOnce() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.mainContext

        try persistence.prepareRequiredRecords(context: context)
        try persistence.prepareRequiredRecords(context: context)

        let settingsCount = try context.fetchCount(FetchDescriptor<AppSettingsRecord>())
        XCTAssertEqual(settingsCount, 1)
    }

    func testPrepareRequiredRecordsNormalizesLegacySettings() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.mainContext
        let settings = AppSettingsRecord()
        settings.defaultDurationMinutes = -30
        settings.defaultNumberOfHalves = 99
        settings.themeAccentRawValue = "legacyAccent"
        settings.quickActionsData = Data([0xFF])
        context.insert(settings)
        try context.save()

        try persistence.prepareRequiredRecords(context: context)

        let storedSettings = try XCTUnwrap(context.fetch(FetchDescriptor<AppSettingsRecord>()).first)
        XCTAssertEqual(storedSettings.defaultDurationMinutes, 1)
        XCTAssertEqual(storedSettings.defaultNumberOfHalves, 4)
        XCTAssertEqual(storedSettings.themeAccentRawValue, AppThemeAccent.stadiumGreen.rawValue)
        XCTAssertEqual(storedSettings.quickActions, QuickActionConfiguration())
    }

    func testPrepareRequiredRecordsRemovesDuplicateSettings() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.mainContext
        let firstSettings = AppSettingsRecord(defaultDurationMinutes: -30)
        let duplicateSettings = AppSettingsRecord(defaultDurationMinutes: -40)
        context.insert(firstSettings)
        context.insert(duplicateSettings)
        try context.save()

        try persistence.prepareRequiredRecords(context: context)

        let storedSettings = try context.fetch(FetchDescriptor<AppSettingsRecord>())
        XCTAssertEqual(storedSettings.count, 1)
        XCTAssertEqual(storedSettings.first?.defaultDurationMinutes, 1)
    }

    func testPrepareRequiredRecordsKeepsDeterministicSettingsRecordWhenRemovingDuplicates() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.mainContext
        let higherIDSettings = AppSettingsRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            defaultDurationMinutes: 45
        )
        let lowerIDSettings = AppSettingsRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            defaultDurationMinutes: -30
        )
        context.insert(higherIDSettings)
        context.insert(lowerIDSettings)
        try context.save()

        try persistence.prepareRequiredRecords(context: context)

        let storedSettings = try context.fetch(FetchDescriptor<AppSettingsRecord>())
        XCTAssertEqual(storedSettings.count, 1)
        XCTAssertEqual(storedSettings.first?.id, lowerIDSettings.id)
        XCTAssertEqual(storedSettings.first?.defaultDurationMinutes, 1)
    }

    func testPreferredSettingsRecordUsesStableIDOrder() {
        let higherIDSettings = AppSettingsRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            defaultDurationMinutes: 45
        )
        let lowerIDSettings = AppSettingsRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            defaultDurationMinutes: 90
        )

        let preferredSettings = [higherIDSettings, lowerIDSettings].preferredSettingsRecord

        XCTAssertEqual(preferredSettings?.id, lowerIDSettings.id)
    }

    func testAdvanceHalfClampsOutOfRangePeriodBeforeFinishing() {
        let match = makeMatch()
        match.currentHalf = 99
        let engine = MatchEngine()
        engine.select(match: match)

        engine.advanceHalf()

        XCTAssertEqual(match.currentHalf, 2)
        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testAdvanceHalfNormalizesOutOfRangePeriodCountBeforeFinishing() {
        let match = makeMatch()
        match.numberOfHalves = 99
        match.currentHalf = 4
        let engine = MatchEngine()
        engine.select(match: match)

        engine.advanceHalf()

        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testAdvanceHalfNormalizesLegacyMatchState() {
        let match = makeMatch()
        match.durationMinutes = -12
        match.numberOfHalves = 4
        match.currentHalf = 1
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let engine = MatchEngine()
        engine.select(match: match)

        engine.advanceHalf()

        XCTAssertEqual(match.durationMinutes, 1)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 2)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testAdvanceHalfFlowsThroughPreEnabledExtraTime() {
        let match = MatchRecord(
            title: "Cup Final",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            extraTimeEnabled: true
        )
        let engine = MatchEngine()
        engine.select(match: match)

        engine.advanceHalf()
        XCTAssertEqual(match.currentHalf, 2)
        XCTAssertFalse(match.isFinished)

        engine.advanceHalf()
        XCTAssertEqual(match.currentHalf, 3)
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 1")
        XCTAssertFalse(match.isFinished)

        engine.advanceHalf()
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 2")
        XCTAssertFalse(match.isFinished)

        engine.advanceHalf()
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertTrue(match.isFinished)
    }

    func testStartExtraTimeAtFullTimeKeepsClockContinuous() {
        let match = makeMatch()
        match.currentHalf = 2
        match.elapsedSeconds = 90 * 60
        let engine = MatchEngine()
        engine.select(match: match)

        engine.startExtraTime()

        XCTAssertTrue(match.usesExtraTime)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 3)
        XCTAssertEqual(match.currentHalfTitle, "Extra Time 1")
        XCTAssertEqual(match.elapsedSeconds, 90 * 60)
        XCTAssertTrue(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testStartExtraTimeDoesNothingBeforeFullTime() {
        let match = makeMatch()
        let engine = MatchEngine()
        engine.select(match: match)

        engine.startExtraTime()

        XCTAssertFalse(match.usesExtraTime)
        XCTAssertEqual(match.currentHalf, 1)
        XCTAssertEqual(match.totalPeriodNumber, 2)
    }

    func testStartNormalizesOutOfRangePeriodState() {
        let match = makeMatch()
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.isLive = false
        match.isFinished = true
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertTrue(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testStartAndTickNormalizeNegativeElapsedSeconds() {
        let match = makeMatch()
        match.elapsedSeconds = -9
        let engine = MatchEngine()

        engine.start(match: match)
        XCTAssertEqual(match.elapsedSeconds, 0)

        engine.tick()
        XCTAssertEqual(match.elapsedSeconds, 1)
    }

    func testTickNormalizesLegacyMatchStateBeforeIncrementingClock() {
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let engine = MatchEngine()
        engine.select(match: match)

        engine.tick()

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 1)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
    }

    func testStartNormalizesNegativeScores() {
        let match = makeMatch()
        match.homeScore = -2
        match.awayScore = -3
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
    }

    func testStartNormalizesOutOfRangeDuration() {
        let match = makeMatch()
        match.durationMinutes = 999
        let engine = MatchEngine()

        engine.start(match: match)

        XCTAssertEqual(match.durationMinutes, 130)
    }

    func testEndMatchNormalizesLegacyMatchState() {
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let engine = MatchEngine()
        engine.select(match: match)

        engine.endMatch()

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testTogglePauseNormalizesLegacyMatchState() {
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let engine = MatchEngine()
        engine.select(match: match)

        engine.togglePause()

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertFalse(match.isLive)
        XCTAssertFalse(match.isFinished)
    }

    func testLoggingOutOfRangeCurrentHalfUsesClampedPeriod() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 111)
        )

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.period), [.extraTimeSecondHalf])
    }

    func testDraftLoggingNormalizesLegacyMatchStateBeforeSaving() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        context.insert(match)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(type: .shotOnTarget, teamSide: .home, tag: "Chance"),
            to: match,
            context: context
        )

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.period), [.extraTimeSecondHalf])
    }

    func testLoggingNormalizesNegativeScoresBeforeApplyingGoal() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = -4
        match.awayScore = -3
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(
            eventType: .goal,
            in: match,
            context: context,
            teamSide: .opponent,
            timestamp: Date(timeIntervalSince1970: 112)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)
    }

    func testUndoRemovesLinkedFoulPair() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(
            eventType: .foulCommitted,
            in: match,
            context: context,
            teamSide: .home,
            notes: "Trip",
            timestamp: Date(timeIntervalSince1970: 102)
        )

        XCTAssertEqual(Set(match.events.map(\.eventType)), [.foulCommitted, .foulWon])
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3

        try engine.undoLastEvent(context: context)

        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testUndoDoesNotRemoveUnrelatedSameTimestampEvent() throws {
        let context = try makeContext()
        let match = makeMatch()
        let sharedTimestamp = Date(timeIntervalSince1970: 102.5)
        let unrelatedShot = MatchEventRecord(
            timestamp: sharedTimestamp,
            matchMinute: 2,
            period: .firstHalf,
            eventType: .shotOnTarget,
            teamSide: .home,
            match: match
        )
        match.events.append(unrelatedShot)
        context.insert(match)
        context.insert(unrelatedShot)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(
            eventType: .foulCommitted,
            in: match,
            context: context,
            teamSide: .home,
            notes: "Trip",
            timestamp: sharedTimestamp
        )

        try engine.undoLastEvent(context: context)

        XCTAssertEqual(match.events.map(\.id), [unrelatedShot.id])
    }

    func testFoulDraftCreatesAndDeletesLinkedFoulPair() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.applyDraft(
            EventDraft(
                type: .foulCommitted,
                teamSide: .home,
                tag: "Trip"
            ),
            to: match,
            context: context
        )

        XCTAssertEqual(Set(match.events.map(\.eventType)), [.foulCommitted, .foulWon])
        XCTAssertEqual(match.events.first { $0.eventType == .foulCommitted }?.teamSide, .home)
        XCTAssertEqual(match.events.first { $0.eventType == .foulWon }?.teamSide, .opponent)

        let foul = try XCTUnwrap(match.events.first { $0.eventType == .foulCommitted })
        try engine.deleteEventGroup(containing: foul, in: match, context: context)

        XCTAssertTrue(match.events.isEmpty)
    }

    func testDirectLoggingFinishedMatchThrowsWithoutMutating() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.isLive = false
        match.isFinished = true
        context.insert(match)

        let engine = MatchEngine()

        XCTAssertThrowsError(
            try engine.log(
                eventType: .goal,
                in: match,
                context: context,
                teamSide: .home
            )
        ) { error in
            XCTAssertEqual(error as? MatchEngineError, .matchFinished)
        }

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDraftLoggingFinishedMatchThrowsWithoutMutating() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.isLive = false
        match.isFinished = true
        context.insert(match)

        let engine = MatchEngine()

        XCTAssertThrowsError(
            try engine.applyDraft(
                EventDraft(type: .foulCommitted, teamSide: .home, tag: "Trip"),
                to: match,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? MatchEngineError, .matchFinished)
        }

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testDeletingFinishedMatchEventThrowsWithoutMutating() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(eventType: .goal, in: match, context: context, teamSide: .home)
        let event = try XCTUnwrap(match.events.first)
        match.isLive = false
        match.isFinished = true

        XCTAssertThrowsError(
            try engine.deleteEventGroup(containing: event, in: match, context: context)
        ) { error in
            XCTAssertEqual(error as? MatchEngineError, .matchFinished)
        }

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testUndoFinishedMatchThrowsWithoutMutating() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(eventType: .goal, in: match, context: context, teamSide: .home)
        match.isLive = false
        match.isFinished = true

        XCTAssertThrowsError(
            try engine.undoLastEvent(context: context)
        ) { error in
            XCTAssertEqual(error as? MatchEngineError, .matchFinished)
        }

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testFinishedMatchCannotBeResumedOrAdvanced() {
        let match = makeMatch()
        match.isLive = false
        match.isFinished = true
        match.currentHalf = 2

        let engine = MatchEngine()
        engine.select(match: match)

        engine.togglePause()
        engine.advanceHalf()

        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
        XCTAssertEqual(match.currentHalf, 2)
    }

    func testSanitizedTrackedEventsPreservesIntentionalEmptySelection() {
        XCTAssertEqual(MatchEventType.sanitizedTrackedEvents(from: []), [])
        XCTAssertEqual(MatchEventType.sanitizedTrackedEvents(fromRawValues: []), [])
    }

    func testSanitizedTrackedEventsDropsNonConfigurableEventsAndUsesCanonicalOrder() {
        let events = MatchEventType.sanitizedTrackedEvents(from: [
            .foulWon,
            .yellowCard,
            .assist,
            .goal,
            .goal,
            .shotOnTarget
        ])

        XCTAssertEqual(events, [.goal, .shotOnTarget, .yellowCard])
    }

    func testSanitizedTrackedEventsTrimsSavedRawValues() {
        let events = MatchEventType.sanitizedTrackedEvents(fromRawValues: [
            " goal ",
            "\nyellowCard\t",
            MatchEventType.assist.rawValue
        ])

        XCTAssertEqual(events, [.goal, .yellowCard])
    }

    func testSanitizedTrackedEventsFallsBackForLegacyRawValuesWithoutConfigurableMatches() {
        let events = MatchEventType.sanitizedTrackedEvents(fromRawValues: [
            MatchEventType.foulWon.rawValue,
            MatchEventType.assist.rawValue,
            "futureEvent"
        ])

        XCTAssertEqual(events, MatchEventType.defaultQuickActions)
    }

    func testDefaultQuickActionsUseCanonicalSanitizedOrder() {
        XCTAssertEqual(
            MatchEventType.defaultQuickActions,
            MatchEventType.sanitizedTrackedEvents(from: MatchEventType.defaultQuickActions)
        )
    }

    func testWatchEventGroupsIncludeEveryConfigurableActionOnce() {
        let watchEvents = MatchEventType.watchPrimaryGroup + MatchEventType.watchSecondaryGroup + MatchEventType.watchMoreGroup

        XCTAssertTrue(MatchEventType.configurableQuickActions.contains(.ownGoal))
        XCTAssertEqual(Set(watchEvents), Set(MatchEventType.configurableQuickActions))
        XCTAssertEqual(watchEvents.count, Set(watchEvents).count)
    }

    func testQuickActionConfigurationDecodesLegacyPayloadWithDefaults() throws {
        let legacyData = try XCTUnwrap("""
        {
            "enabledActions": ["assist", "yellowCard", "goal", "foulWon"],
            "smartDetailEnabled": false
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: legacyData)

        XCTAssertEqual(config.enabledActions, [.goal, .yellowCard])
        XCTAssertFalse(config.smartDetailEnabled)
        XCTAssertTrue(config.watchHapticsEnabled)
        XCTAssertEqual(config.playerTrackingMode, .optional)
        XCTAssertTrue(config.favoritePlayerIDs.isEmpty)
    }

    func testQuickActionConfigurationIgnoresUnknownSavedValuesWithoutDroppingValidSettings() throws {
        let data = try XCTUnwrap("""
        {
            "enabledActions": ["futureEvent", 42, " yellowCard ", null, {"rawValue": "redCard"}, "\\ngoal\\t"],
            "smartDetailEnabled": false,
            "watchHapticsEnabled": false,
            "playerTrackingMode": "futureMode"
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: data)

        XCTAssertEqual(config.enabledActions, [.goal, .yellowCard])
        XCTAssertFalse(config.smartDetailEnabled)
        XCTAssertFalse(config.watchHapticsEnabled)
        XCTAssertEqual(config.playerTrackingMode, .optional)
        XCTAssertTrue(config.favoritePlayerIDs.isEmpty)
    }

    func testQuickActionConfigurationFallsBackWhenLegacyActionsHaveNoConfigurableMatches() throws {
        let data = try XCTUnwrap("""
        {
            "enabledActions": ["assist", "foulWon", "futureEvent"]
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: data)

        XCTAssertEqual(config.enabledActions, MatchEventType.defaultQuickActions)
    }

    func testQuickActionConfigurationFallsBackWhenSavedActionsAreAllMalformed() throws {
        let data = try XCTUnwrap("""
        {
            "enabledActions": [42, null, {"rawValue": "goal"}]
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: data)

        XCTAssertEqual(config.enabledActions, MatchEventType.defaultQuickActions)
    }

    func testQuickActionConfigurationPreservesIntentionalEmptySavedActions() throws {
        let data = try XCTUnwrap("""
        {
            "enabledActions": []
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: data)

        XCTAssertEqual(config.enabledActions, [])
    }

    func testQuickActionConfigurationCanonicalizesFavoritePlayerIDs() throws {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let data = try XCTUnwrap("""
        {
            "favoritePlayerIDs": [
                "\(firstID.uuidString)",
                42,
                "not-a-player-id",
                null,
                {"id": "\(secondID.uuidString)"},
                " \(secondID.uuidString)\\n",
                "\(firstID.uuidString)"
            ]
        }
        """.data(using: .utf8))

        let config = try JSONDecoder().decode(QuickActionConfiguration.self, from: data)
        let initializedConfig = QuickActionConfiguration(favoritePlayerIDs: [firstID, secondID, firstID])
        let encodedData = try JSONEncoder().encode(initializedConfig)
        let encodedConfig = try JSONDecoder().decode(QuickActionConfiguration.self, from: encodedData)

        XCTAssertEqual(config.favoritePlayerIDs, [firstID, secondID])
        XCTAssertEqual(initializedConfig.favoritePlayerIDs, [firstID, secondID])
        XCTAssertEqual(encodedConfig.favoritePlayerIDs, [firstID, secondID])
    }

    func testMatchRecordSanitizesTrackedEventsAtModelBoundary() {
        let match = makeMatch(trackedEventTypes: [
            .assist,
            .yellowCard,
            .foulWon,
            .goal,
            .goal,
            .shotOnTarget
        ])

        XCTAssertEqual(match.trackedEventTypes, [.goal, .shotOnTarget, .yellowCard])
        XCTAssertEqual(match.trackedEventTypeRawValues, [
            MatchEventType.goal.rawValue,
            MatchEventType.shotOnTarget.rawValue,
            MatchEventType.yellowCard.rawValue
        ])

        match.trackedEventTypeRawValues = [
            MatchEventType.foulWon.rawValue,
            MatchEventType.assist.rawValue,
            MatchEventType.yellowCard.rawValue,
            MatchEventType.goal.rawValue
        ]

        XCTAssertEqual(match.trackedEventTypes, [.goal, .yellowCard])
    }

    func testMatchRecordFallsBackWhenLegacyTrackedEventsHaveNoConfigurableMatches() {
        let match = makeMatch()
        match.trackedEventTypeRawValues = [
            MatchEventType.foulWon.rawValue,
            MatchEventType.assist.rawValue,
            "futureEvent"
        ]

        XCTAssertEqual(match.trackedEventTypes, MatchEventType.defaultQuickActions)
    }

    func testMatchRecordPreservesIntentionalEmptyTrackedEvents() {
        let match = makeMatch(trackedEventTypes: [])

        XCTAssertEqual(match.trackedEventTypes, [])
        XCTAssertEqual(match.trackedEventTypeRawValues, [])
    }

    func testAnalyticsTotalShotsIncludesGoals() {
        let match = makeMatch()
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 190),
                matchMinute: 11,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 191),
                matchMinute: 12,
                period: .firstHalf,
                eventType: .shotOnTarget,
                teamSide: .home,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 192),
                matchMinute: 13,
                period: .firstHalf,
                eventType: .shotOffTarget,
                teamSide: .home,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Shots On"), 1)
        XCTAssertEqual(summary.value(for: "Shots Off"), 1)
        XCTAssertEqual(summary.value(for: "Total Shots"), 3)
        XCTAssertEqual(summary.attackInvolvement, 3)
    }

    func testAnalyticsShotOnTargetRollsIntoTotalShotsWithoutSyntheticEvents() {
        let match = makeMatch()
        let shooter = PlayerRecord(name: "Shooter", teamSide: .home, match: match)
        match.players.append(shooter)
        match.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 193),
                matchMinute: 14,
                period: .firstHalf,
                eventType: .shotOnTarget,
                teamSide: .home,
                playerID: shooter.id,
                match: match
            )
        )

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 0)
        XCTAssertEqual(summary.value(for: "Shots On"), 1)
        XCTAssertEqual(summary.value(for: "Shots Off"), 0)
        XCTAssertEqual(summary.value(for: "Total Shots"), 1)
        XCTAssertEqual(summary.attackInvolvement, 1)
        XCTAssertEqual(match.events.count, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.shotOnTarget])
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Shooter")
        XCTAssertEqual(summary.topAttackingContributor?.stats[.shotOnTarget], 1)
        XCTAssertNil(summary.topAttackingContributor?.stats[.shotOffTarget])
        XCTAssertNil(summary.topAttackingContributor?.stats[.goal])
    }

    func testAnalyticsInfersLegacyGoalAssistFromSecondaryPlayer() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 200),
                matchMinute: 12,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: assister.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 210),
                matchMinute: 13,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: assister.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Assists"), 1)
        XCTAssertEqual(summary.attackInvolvement, 3)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Assister")
        XCTAssertEqual(summary.topAttackingContributor?.stats[.assist], 1)
    }

    func testAnalyticsDoesNotDoubleCountLinkedAssist() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let timestamp = Date(timeIntervalSince1970: 220)
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 14,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: assister.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 14,
                period: .firstHalf,
                eventType: .assist,
                teamSide: .home,
                playerID: assister.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Assists"), 1)
        XCTAssertEqual(summary.attackInvolvement, 2)
    }

    func testAnalyticsInfersAssistWhenLinkedAssistHasInvalidPeriod() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let timestamp = Date(timeIntervalSince1970: 225)
        let linkedGroupID = UUID()
        match.players.append(contentsOf: [scorer, assister])
        let goal = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 14,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            playerID: scorer.id,
            secondaryPlayerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        let invalidAssist = MatchEventRecord(
            timestamp: timestamp,
            matchMinute: 14,
            period: .firstHalf,
            eventType: .assist,
            teamSide: .home,
            playerID: assister.id,
            linkedGroupID: linkedGroupID,
            match: match
        )
        invalidAssist.periodRawValue = "futurePeriod"
        match.events.append(contentsOf: [goal, invalidAssist])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Assists"), 1)
        XCTAssertEqual(summary.attackInvolvement, 2)
    }

    func testAnalyticsWrongSideLinkedAssistDoesNotSuppressInferredAssist() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 221)
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 14,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: assister.id,
                linkedGroupID: linkedGroupID,
                match: match
            ),
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 14,
                period: .firstHalf,
                eventType: .assist,
                teamSide: .opponent,
                playerID: assister.id,
                linkedGroupID: linkedGroupID,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Assists"), 1)
        XCTAssertEqual(summary.attackInvolvement, 2)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Assister")
        XCTAssertEqual(summary.topAttackingContributor?.stats[.assist], 1)
    }

    func testAnalyticsUnrelatedSameGroupAssistDoesNotSuppressInferredAssist() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let assister = PlayerRecord(name: "Assister", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        match.players.append(contentsOf: [scorer, assister])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 221.5),
                matchMinute: 14,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: assister.id,
                linkedGroupID: linkedGroupID,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 222.5),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .assist,
                teamSide: .home,
                playerID: assister.id,
                linkedGroupID: linkedGroupID,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Assists"), 2)
        XCTAssertEqual(summary.attackInvolvement, 3)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Assister")
        XCTAssertEqual(summary.topAttackingContributor?.stats[.assist], 2)
    }

    func testAnalyticsDoesNotCreditWrongSidePlayerReference() throws {
        let match = makeMatch()
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(opponentPlayer)
        match.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 225),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .shotOnTarget,
                teamSide: .home,
                playerID: opponentPlayer.id,
                match: match
            )
        )

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Shots On"), 1)
        XCTAssertEqual(summary.attackInvolvement, 1)
        XCTAssertNil(summary.mostActivePlayer)
        XCTAssertNil(match.player(for: try XCTUnwrap(match.events.first)))
    }

    func testAnalyticsKeepsDuplicatePlayerIDsSeparateAcrossTeamSides() {
        let match = makeMatch()
        let sharedPlayerID = UUID()
        let homePlayer = PlayerRecord(id: sharedPlayerID, name: "Home Player", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(id: sharedPlayerID, name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [homePlayer, opponentPlayer])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 225.1),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: sharedPlayerID,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 225.2),
                matchMinute: 16,
                period: .firstHalf,
                eventType: .tackleWon,
                teamSide: .opponent,
                playerID: sharedPlayerID,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 225.3),
                matchMinute: 17,
                period: .firstHalf,
                eventType: .interception,
                teamSide: .opponent,
                playerID: sharedPlayerID,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match, scope: .both)

        XCTAssertEqual(summary.mostActivePlayer?.playerName, "Opponent Player")
        XCTAssertEqual(summary.mostActivePlayer?.playerID, sharedPlayerID)
        XCTAssertEqual(summary.mostActivePlayer?.teamSide, .opponent)
        XCTAssertEqual(summary.mostActivePlayer?.id, "\(TeamSide.opponent.rawValue)-\(sharedPlayerID.uuidString)")
        XCTAssertEqual(summary.mostActivePlayer?.stats.values.reduce(0, +), 2)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Home Player")
        XCTAssertEqual(summary.topAttackingContributor?.playerID, sharedPlayerID)
        XCTAssertEqual(summary.topAttackingContributor?.teamSide, .home)
        XCTAssertEqual(summary.topAttackingContributor?.id, "\(TeamSide.home.rawValue)-\(sharedPlayerID.uuidString)")
        XCTAssertEqual(summary.topDefensiveContributor?.playerName, "Opponent Player")
    }

    func testAnalyticsDoesNotInferAssistFromWrongSideSecondaryPlayer() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        let opponentPlayer = PlayerRecord(name: "Opponent Player", teamSide: .opponent, match: match)
        match.players.append(contentsOf: [scorer, opponentPlayer])
        match.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 226),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: opponentPlayer.id,
                match: match
            )
        )

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Assists"), 0)
        XCTAssertEqual(summary.attackInvolvement, 1)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Scorer")
        XCTAssertNil(summary.topAttackingContributor?.stats[.assist])
    }

    func testAnalyticsDoesNotInferSelfAssistFromLegacyGoal() {
        let match = makeMatch()
        let scorer = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        match.players.append(scorer)
        match.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 227),
                matchMinute: 16,
                period: .firstHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: scorer.id,
                secondaryPlayerID: scorer.id,
                match: match
            )
        )

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Assists"), 0)
        XCTAssertEqual(summary.attackInvolvement, 1)
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Scorer")
        XCTAssertNil(summary.topAttackingContributor?.stats[.assist])
    }

    func testAnalyticsCountsOwnGoalsSeparatelyFromPlayerGoals() {
        let match = makeMatch()
        let defender = PlayerRecord(name: "Defender", teamSide: .home, match: match)
        match.players.append(defender)
        match.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 227.5),
                matchMinute: 18,
                period: .firstHalf,
                eventType: .ownGoal,
                teamSide: .home,
                playerID: defender.id,
                match: match
            )
        )

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 0)
        XCTAssertEqual(summary.value(for: "Own Goals"), 1)
        XCTAssertEqual(summary.value(for: "Assists"), 0)
        XCTAssertEqual(summary.attackInvolvement, 0)
        XCTAssertEqual(summary.mostActivePlayer?.playerName, "Defender")
        XCTAssertEqual(summary.mostActivePlayer?.stats[.ownGoal], 1)
        XCTAssertNil(summary.mostActivePlayer?.stats[.goal])
        XCTAssertNil(summary.topAttackingContributor)
    }

    func testAnalyticsCountsSecondYellowAndAutomaticRedForPlayerDiscipline() {
        let match = makeMatch()
        let player = PlayerRecord(name: "Booked Player", teamSide: .home, match: match)
        let linkedGroupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 227.75)
        match.players.append(player)
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 227.25),
                matchMinute: 18,
                period: .firstHalf,
                eventType: .yellowCard,
                teamSide: .home,
                playerID: player.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 19,
                period: .firstHalf,
                eventType: .yellowCard,
                teamSide: .home,
                playerID: player.id,
                linkedGroupID: linkedGroupID,
                match: match
            ),
            MatchEventRecord(
                timestamp: timestamp,
                matchMinute: 19,
                period: .firstHalf,
                eventType: .redCard,
                teamSide: .home,
                playerID: player.id,
                linkedGroupID: linkedGroupID,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Yellow Cards"), 2)
        XCTAssertEqual(summary.value(for: "Red Cards"), 1)
        XCTAssertEqual(summary.discipline, 3)
        XCTAssertEqual(summary.mostActivePlayer?.playerName, "Booked Player")
        XCTAssertEqual(summary.mostActivePlayer?.stats[.yellowCard], 2)
        XCTAssertEqual(summary.mostActivePlayer?.stats[.redCard], 1)
    }

    func testAnalyticsStatLineIDsStayStableAcrossRebuilds() {
        let match = makeMatch()

        let firstSummary = MatchAnalyticsService().buildSummary(for: match)
        let secondSummary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(firstSummary.teamTotals.map(\.id), secondSummary.teamTotals.map(\.id))
        XCTAssertEqual(firstSummary.teamTotals.map(\.id), firstSummary.teamTotals.map(\.title))
    }

    func testAnalyticsTopPlayerTiesUseStableDisplayNameOrder() {
        let match = makeMatch()
        let zed = PlayerRecord(name: "Zed", teamSide: .home, match: match)
        let ada = PlayerRecord(name: "Ada", teamSide: .home, match: match)
        match.players.append(contentsOf: [zed, ada])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 231),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: zed.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 232),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: ada.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.mostActivePlayer?.playerName, "Ada")
        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Ada")
    }

    func testAnalyticsTopPlayerTiesUseStableIDOrderForDuplicateNames() {
        let match = makeMatch()
        let lowerIDPlayer = PlayerRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Sam",
            teamSide: .home,
            match: match
        )
        let higherIDPlayer = PlayerRecord(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            name: "Sam",
            teamSide: .home,
            match: match
        )
        match.players.append(contentsOf: [higherIDPlayer, lowerIDPlayer])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 233),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: higherIDPlayer.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 234),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: lowerIDPlayer.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.mostActivePlayer?.playerID, lowerIDPlayer.id)
        XCTAssertEqual(summary.topAttackingContributor?.playerID, lowerIDPlayer.id)
    }

    func testAnalyticsCategoryLeadersRequirePositiveCategoryScore() {
        let match = makeMatch()
        let attacker = PlayerRecord(name: "Attacker", teamSide: .home, match: match)
        let defender = PlayerRecord(name: "Defender", teamSide: .home, match: match)
        match.players.append(contentsOf: [attacker, defender])
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 235),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: attacker.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 236),
                matchMinute: 16,
                period: .firstHalf,
                eventType: .tackleWon,
                teamSide: .home,
                playerID: defender.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.topAttackingContributor?.playerName, "Attacker")
        XCTAssertEqual(summary.topDefensiveContributor?.playerName, "Defender")
    }

    func testAnalyticsDoesNotReportZeroScoreCategoryLeader() {
        let attackingOnlyMatch = makeMatch()
        let attacker = PlayerRecord(name: "Attacker", teamSide: .home, match: attackingOnlyMatch)
        attackingOnlyMatch.players.append(attacker)
        attackingOnlyMatch.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 237),
                matchMinute: 15,
                period: .firstHalf,
                eventType: .keyPass,
                teamSide: .home,
                playerID: attacker.id,
                match: attackingOnlyMatch
            )
        )

        let defensiveOnlyMatch = makeMatch()
        let defender = PlayerRecord(name: "Defender", teamSide: .home, match: defensiveOnlyMatch)
        defensiveOnlyMatch.players.append(defender)
        defensiveOnlyMatch.events.append(
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 238),
                matchMinute: 16,
                period: .firstHalf,
                eventType: .tackleWon,
                teamSide: .home,
                playerID: defender.id,
                match: defensiveOnlyMatch
            )
        )

        XCTAssertNil(MatchAnalyticsService().buildSummary(for: attackingOnlyMatch).topDefensiveContributor)
        XCTAssertNil(MatchAnalyticsService().buildSummary(for: defensiveOnlyMatch).topAttackingContributor)
    }

    func testAnalyticsIgnoresInvalidRawEventRows() {
        let match = makeMatch()
        let invalidTypeEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 230),
            matchMinute: 15,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidTypeEvent.eventTypeRawValue = "legacyEvent"
        let invalidTeamEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 240),
            matchMinute: 16,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidTeamEvent.teamSideRawValue = "visitor"
        let invalidPeriodEvent = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 250),
            matchMinute: 17,
            period: .firstHalf,
            eventType: .goal,
            teamSide: .home,
            match: match
        )
        invalidPeriodEvent.periodRawValue = "futurePeriod"
        match.events.append(contentsOf: [invalidTypeEvent, invalidTeamEvent, invalidPeriodEvent])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.value(for: "Goals"), 0)
        XCTAssertEqual(summary.attackInvolvement, 0)
        XCTAssertEqual(invalidTypeEvent.displayTitle, "Unknown Event")
        XCTAssertFalse(invalidTypeEvent.hasValidRawValues)
        XCTAssertFalse(invalidTeamEvent.hasValidRawValues)
        XCTAssertFalse(invalidPeriodEvent.hasValidRawValues)
        XCTAssertNil(invalidPeriodEvent.validPeriod)
    }

    func testPenaltyShootoutScoredAttemptUpdatesOnlyPenaltyScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        match.awayScore = 1
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        engine.startPenaltyShootout()
        try engine.log(
            eventType: .penaltyScored,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 260)
        )

        XCTAssertEqual(match.shootoutStatus, .inProgress)
        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.homePenaltyScore, 1)
        XCTAssertEqual(match.awayPenaltyScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.penaltyScored])
        XCTAssertEqual(match.events.map(\.period), [.penalties])
        XCTAssertEqual(match.displayScoreLine, "Midline FC 1 - 1 Rivals FC (1-0 pens)")
    }

    func testPenaltyShootoutMissedAndSavedDoNotChangeAnyScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        engine.startPenaltyShootout()
        try engine.log(
            eventType: .penaltyMissed,
            in: match,
            context: context,
            teamSide: .home,
            timestamp: Date(timeIntervalSince1970: 260.1)
        )
        try engine.log(
            eventType: .penaltySaved,
            in: match,
            context: context,
            teamSide: .opponent,
            timestamp: Date(timeIntervalSince1970: 260.2)
        )

        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.homePenaltyScore, 0)
        XCTAssertEqual(match.awayPenaltyScore, 0)
        XCTAssertEqual(match.events.sortedForTimeline().map(\.eventType), [.penaltyMissed, .penaltySaved])
        XCTAssertEqual(Set(match.events.map(\.period)), [.penalties])
    }

    func testPenaltyShootoutRejectsNormalEventsAndRequiresActiveShootout() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)

        XCTAssertThrowsError(try engine.log(eventType: .penaltyScored, in: match, context: context, teamSide: .home)) { error in
            XCTAssertEqual(error as? MatchEngineError, .shootoutNotActive)
        }

        engine.startPenaltyShootout()
        XCTAssertThrowsError(try engine.log(eventType: .goal, in: match, context: context, teamSide: .home)) { error in
            XCTAssertEqual(error as? MatchEngineError, .shootoutActive)
        }
        XCTAssertTrue(match.events.isEmpty)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.homePenaltyScore, 0)
    }

    func testUndoAndDeletePenaltyScoredRestoreOnlyPenaltyScore() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.homeScore = 1
        match.awayScore = 1
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        engine.startPenaltyShootout()
        try engine.log(eventType: .penaltyScored, in: match, context: context, teamSide: .home, timestamp: Date(timeIntervalSince1970: 261))
        try engine.undoLastEvent(context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.homePenaltyScore, 0)
        XCTAssertTrue(match.events.isEmpty)

        try engine.log(eventType: .penaltyScored, in: match, context: context, teamSide: .opponent, timestamp: Date(timeIntervalSince1970: 262))
        let event = try XCTUnwrap(match.events.first)
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.awayPenaltyScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testFinishPenaltyShootoutEndsMatch() throws {
        let match = makeMatch()
        match.homeScore = 2
        match.awayScore = 2
        let engine = MatchEngine()
        engine.select(match: match)

        engine.startPenaltyShootout()
        engine.finishPenaltyShootout()

        XCTAssertEqual(match.shootoutStatus, .finished)
        XCTAssertFalse(match.isLive)
        XCTAssertTrue(match.isFinished)
    }

    func testAnalyticsKeepsPenaltyShootoutAttemptsSeparateFromNormalStats() {
        let match = makeMatch()
        let player = PlayerRecord(name: "Taker", teamSide: .home, match: match)
        match.players.append(player)
        match.homeScore = 1
        match.awayScore = 1
        match.shootoutStatus = .finished
        match.homePenaltyScore = 1
        match.events.append(contentsOf: [
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 263),
                matchMinute: 89,
                period: .secondHalf,
                eventType: .goal,
                teamSide: .home,
                playerID: player.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 264),
                matchMinute: 91,
                period: .penalties,
                eventType: .penaltyScored,
                teamSide: .home,
                playerID: player.id,
                match: match
            ),
            MatchEventRecord(
                timestamp: Date(timeIntervalSince1970: 265),
                matchMinute: 92,
                period: .penalties,
                eventType: .penaltySaved,
                teamSide: .home,
                playerID: player.id,
                match: match
            )
        ])

        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(summary.scoreLine, "Midline FC 1 - 1 Rivals FC (1-0 pens)")
        XCTAssertEqual(summary.value(for: "Goals"), 1)
        XCTAssertEqual(summary.value(for: "Total Shots"), 1)
        XCTAssertEqual(summary.value(for: "Pens Scored"), 1)
        XCTAssertEqual(summary.value(for: "Pens Saved"), 1)
        XCTAssertEqual(summary.attackInvolvement, 1)
        XCTAssertEqual(summary.topAttackingContributor?.stats[.goal], 1)
        XCTAssertNil(summary.topAttackingContributor?.stats[.penaltyScored])
    }

    func testSubstitutionLimitsDefaultToUnlimited() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.substitution])
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .opponent)

        XCTAssertTrue(match.substitutionsAreUnlimited)
        XCTAssertEqual(match.substitutionCount(for: .home), 2)
        XCTAssertEqual(match.substitutionCount(for: .opponent), 1)
        XCTAssertNil(match.remainingSubstitutions(for: .home))
    }

    func testLimitedSubstitutionsBlockPerTeamAtLimit() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.substitution])
        match.substitutionLimitMode = .limited
        match.substitutionLimit = 1
        context.insert(match)

        let engine = MatchEngine()
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home)

        XCTAssertThrowsError(try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home)) { error in
            XCTAssertEqual(error as? MatchEngineError, .substitutionLimitReached)
        }
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .opponent)

        XCTAssertEqual(match.substitutionCount(for: .home), 1)
        XCTAssertEqual(match.substitutionCount(for: .opponent), 1)
        XCTAssertEqual(match.remainingSubstitutions(for: .home), 0)
        XCTAssertEqual(match.remainingSubstitutions(for: .opponent), 0)
    }

    func testUndoAndDeleteSubstitutionRestoreAllowance() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.substitution])
        match.substitutionLimitMode = .limited
        match.substitutionLimit = 1
        context.insert(match)

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home, timestamp: Date(timeIntervalSince1970: 266))
        try engine.undoLastEvent(context: context)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home, timestamp: Date(timeIntervalSince1970: 267))

        XCTAssertEqual(match.substitutionCount(for: .home), 1)
        XCTAssertEqual(match.remainingSubstitutions(for: .home), 0)

        let event = try XCTUnwrap(match.events.first)
        try engine.deleteEventGroup(containing: event, in: match, context: context)

        XCTAssertEqual(match.substitutionCount(for: .home), 0)
        XCTAssertEqual(match.remainingSubstitutions(for: .home), 1)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home, timestamp: Date(timeIntervalSince1970: 268))
        XCTAssertEqual(match.substitutionCount(for: .home), 1)
    }

    func testSubstitutionLimitSettingsAndDraftNormalizeSafely() {
        let settings = AppSettingsRecord(defaultSubstitutionLimitMode: .limited, defaultSubstitutionLimit: 99)
        settings.normalizePersistedValues()

        XCTAssertEqual(settings.defaultSubstitutionLimitMode, .limited)
        XCTAssertEqual(settings.defaultSubstitutionLimitValue, 12)

        let match = makeMatch()
        match.substitutionLimitMode = .limited
        match.substitutionLimit = 0
        let draft = MatchSetupDraft.duplicate(from: match)

        XCTAssertEqual(match.substitutionLimitValue, 1)
        XCTAssertEqual(draft.substitutionLimitMode, .limited)
        XCTAssertEqual(draft.substitutionLimit, 1)
    }

    #if canImport(WatchConnectivity)
    func testWatchEventMessageRejectsWhenLoggingIsNotConfigured() throws {
        let context = try makeContext()
        let match = makeMatch()
        context.insert(match)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "Match logging is not ready.")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testWatchEventMessageRejectsUntrackedEvents() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.yellowCard.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "Yellow Card is not enabled for this match.")
        XCTAssertTrue(match.events.isEmpty)
    }

    func testWatchEventMessageRejectsInvalidTeamSide() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let invalidReply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": "visitor"
        ])
        let missingReply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue
        ])

        XCTAssertEqual(invalidReply["status"] as? String, "rejected")
        XCTAssertEqual(invalidReply["reason"] as? String, "Invalid event payload.")
        XCTAssertEqual(missingReply["status"] as? String, "rejected")
        XCTAssertEqual(missingReply["reason"] as? String, "Invalid event payload.")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testWatchEventMessageAcceptsTrackedEvents() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.homeScore = -5
        match.awayScore = -6
        match.elapsedSeconds = -12
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(reply["homeScore"] as? Int, 1)
        XCTAssertEqual(reply["awayScore"] as? Int, 0)
        XCTAssertEqual(reply["elapsedSeconds"] as? Int, 0)
        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testWatchEventMessageAppliesOwnGoalToOppositeScore() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.ownGoal])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.ownGoal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(reply["homeScore"] as? Int, 0)
        XCTAssertEqual(reply["awayScore"] as? Int, 1)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.ownGoal])
        XCTAssertEqual(match.events.map(\.teamSide), [.home])
    }

    func testWatchEventMessageShotOnTargetRollsIntoTotalShots() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.shotOnTarget])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.shotOnTarget.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])
        let summary = MatchAnalyticsService().buildSummary(for: match)

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertEqual(match.events.count, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.shotOnTarget])
        XCTAssertEqual(summary.value(for: "Shots On"), 1)
        XCTAssertEqual(summary.value(for: "Shots Off"), 0)
        XCTAssertEqual(summary.value(for: "Total Shots"), 1)
    }

    func testWatchEventMessageRejectsSubstitutionWhenLimitIsExhausted() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.substitution])
        match.substitutionLimitMode = .limited
        match.substitutionLimit = 1
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        try engine.log(eventType: .substitution, in: match, context: context, teamSide: .home)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.substitution.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "No substitutions remaining for this team.")
        XCTAssertEqual(match.substitutionCount(for: .home), 1)
    }

    func testWatchEventMessageRejectsNormalLoggingDuringShootout() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.homeScore = 1
        match.awayScore = 1
        match.shootoutStatus = .inProgress
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "Only penalty kicks can be logged during a shootout.")
        XCTAssertTrue(match.events.isEmpty)
    }

    func testWatchYellowCardWithoutPlayerDoesNotCreateAutomaticRedCard() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.yellowCard])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let firstReply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.yellowCard.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])
        let secondReply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.yellowCard.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(firstReply["status"] as? String, "accepted")
        XCTAssertEqual(secondReply["status"] as? String, "accepted")
        XCTAssertEqual(match.events.map(\.eventType), [.yellowCard, .yellowCard])
        XCTAssertTrue(match.events.allSatisfy { $0.playerID == nil })
        XCTAssertTrue(match.events.allSatisfy { $0.linkedGroupID == nil })
    }

    func testWatchEventMessageTrimsRawPayloadValues() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        context.insert(match)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": " \(match.id.uuidString)\n",
            "eventType": "\t\(MatchEventType.goal.rawValue) ",
            "teamSide": " \(TeamSide.home.rawValue)\n"
        ])

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
        XCTAssertEqual(match.events.map(\.teamSide), [.home])
    }

    func testWatchEventMessageRejectsInactiveMatch() throws {
        let context = try makeContext()
        let activeMatch = makeMatch(trackedEventTypes: [.goal])
        let staleMatch = makeMatch(trackedEventTypes: [.goal])
        context.insert(activeMatch)
        context.insert(staleMatch)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: activeMatch)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": staleMatch.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "Match is no longer active.")
        XCTAssertEqual(staleMatch.homeScore, 0)
        XCTAssertTrue(staleMatch.events.isEmpty)
    }

    func testWatchAcceptedReplyParsesScoreSnapshot() {
        let result = MatchSyncService.deliveryResult(from: [
            "status": "accepted",
            "homeScore": -2,
            "awayScore": -1,
            "elapsedSeconds": -482
        ])

        XCTAssertEqual(result, .accepted(WatchMatchSnapshot(
            homeScore: 0,
            awayScore: 0,
            elapsedSeconds: 0
        )))
    }

    func testWatchReplyTrimsAcceptedStatus() {
        let result = MatchSyncService.deliveryResult(from: [
            "status": " accepted\n",
            "homeScore": 2,
            "awayScore": 1,
            "elapsedSeconds": 482
        ])

        XCTAssertEqual(result, .accepted(WatchMatchSnapshot(
            homeScore: 2,
            awayScore: 1,
            elapsedSeconds: 482
        )))
    }

    func testWatchRejectedReplySanitizesReason() {
        let blankResult = MatchSyncService.deliveryResult(from: [
            "status": "rejected",
            "reason": " \n\t "
        ])
        let multilineResult = MatchSyncService.deliveryResult(from: [
            "status": "rejected",
            "reason": " Match\nlogging\tis unavailable. "
        ])

        XCTAssertEqual(blankResult, .rejected("iPhone could not save the event."))
        XCTAssertEqual(multilineResult, .rejected("Match logging is unavailable."))
    }

    func testSyncServiceAppliesWatchApplicationContextThroughHandler() {
        let syncService = MatchSyncService()
        var receivedContext: [String: Any]?
        syncService.watchContextHandler = { context in
            receivedContext = context
        }

        syncService.applyWatchApplicationContext([
            "hasActiveMatch": false
        ])

        XCTAssertEqual(receivedContext?["hasActiveMatch"] as? Bool, false)
    }

    func testWatchLiveStateAppliesActiveMatchContext() {
        let matchID = UUID()
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": matchID.uuidString,
            "teamName": "Midline",
            "opponentName": "Rivals",
            "homeScore": -2,
            "awayScore": -1,
            "half": 2,
            "elapsedSeconds": -615,
            "isLive": true,
            "isFinished": false,
            "trackedEventTypes": [MatchEventType.goal.rawValue],
            "watchHapticsEnabled": false,
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": false
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.activeMatchID, matchID)
        XCTAssertEqual(liveState.teamName, "Midline")
        XCTAssertEqual(liveState.opponentName, "Rivals")
        XCTAssertEqual(liveState.homeScore, 0)
        XCTAssertEqual(liveState.awayScore, 0)
        XCTAssertEqual(liveState.homeScoreValue, 0)
        XCTAssertEqual(liveState.awayScoreValue, 0)
        XCTAssertEqual(liveState.currentHalf, 2)
        XCTAssertEqual(liveState.elapsedSeconds, 0)
        XCTAssertEqual(liveState.clockText, "00:00")
        XCTAssertTrue(liveState.isLive)
        XCTAssertFalse(liveState.watchHapticsEnabled)
        XCTAssertEqual(liveState.trackedEventTypes, [.goal])
        XCTAssertTrue(liveState.watchHomeEventLoggingEnabled)
        XCTAssertFalse(liveState.watchOpponentEventLoggingEnabled)
    }

    func testWatchLiveStateTrimsIncomingMatchID() {
        let matchID = UUID()
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": " \(matchID.uuidString)\n",
            "teamName": "Midline"
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.activeMatchID, matchID)
        XCTAssertEqual(liveState.teamName, "Midline")
    }

    func testWatchLiveStateSelectsAvailableSideWhenCurrentSideBecomesDisabled() {
        let liveState = WatchLiveState()
        liveState.selectedTeamSide = .opponent

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": false
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.selectedTeamSide, .home)
        XCTAssertTrue(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateReportsOnlyAvailableLoggingSides() {
        let liveState = WatchLiveState()

        XCTAssertEqual(liveState.availableLoggingTeamSides, [.home, .opponent])

        liveState.watchHomeEventLoggingEnabled = false
        XCTAssertEqual(liveState.availableLoggingTeamSides, [.opponent])

        liveState.watchOpponentEventLoggingEnabled = false
        XCTAssertTrue(liveState.availableLoggingTeamSides.isEmpty)
    }

    func testWatchLiveStateAppliesTrackedEventsBeforeNormalizingSelectedSide() {
        let liveState = WatchLiveState()
        liveState.trackedEventTypes = [.goal, .shotOnTarget]
        liveState.selectedTeamSide = .opponent

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "trackedEventTypes": [MatchEventType.cornerWon.rawValue],
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": false
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.trackedEventTypes, [.cornerWon])
        XCTAssertEqual(liveState.enabledEvents(from: MatchEventType.watchSecondaryGroup), [.cornerWon])
        XCTAssertEqual(liveState.selectedTeamSide, .home)
        XCTAssertTrue(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateFallsBackWhenLegacyTrackedEventsHaveNoConfigurableMatches() {
        let liveState = WatchLiveState()
        liveState.trackedEventTypes = [.goal]

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "trackedEventTypes": [
                MatchEventType.foulWon.rawValue,
                MatchEventType.assist.rawValue,
                "futureEvent"
            ]
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.trackedEventTypes, MatchEventType.defaultQuickActions)
    }

    func testWatchLiveStatePreservesIntentionalEmptyTrackedEvents() {
        let liveState = WatchLiveState()
        liveState.trackedEventTypes = [.goal]

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "trackedEventTypes": []
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.trackedEventTypes, [])
    }

    func testWatchLiveStateKeepsSelectedSideWhenNoSideCanLog() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID
        liveState.selectedTeamSide = .opponent

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": matchID.uuidString,
            "watchHomeEventLoggingEnabled": false,
            "watchOpponentEventLoggingEnabled": false
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.selectedTeamSide, .opponent)
        XCTAssertFalse(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateFallsBackForBlankIncomingTeamNames() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "teamName": "   ",
            "opponentName": "\n\t"
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.teamName, "Home")
        XCTAssertEqual(liveState.opponentName, "Opponent")

        let symbolApplied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "teamName": "!!!",
            "opponentName": " , # "
        ])

        XCTAssertTrue(symbolApplied)
        XCTAssertEqual(liveState.teamName, "Home")
        XCTAssertEqual(liveState.opponentName, "Opponent")
    }

    func testWatchLiveStateCollapsesIncomingTeamNameLineBreaks() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "teamName": "  Midline\nFC  ",
            "opponentName": "  Rival\tClub  "
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.teamName, "Midline FC")
        XCTAssertEqual(liveState.opponentName, "Rival Club")
    }

    func testWatchLiveStateFailsClosedForInitialPartialActiveContext() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString
        ])

        XCTAssertTrue(applied)
        XCTAssertTrue(liveState.trackedEventTypes.isEmpty)
        XCTAssertFalse(liveState.watchHomeEventLoggingEnabled)
        XCTAssertFalse(liveState.watchOpponentEventLoggingEnabled)
        XCTAssertFalse(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateFailsClosedForSameMatchPartialActiveContext() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID
        liveState.trackedEventTypes = [.goal]
        liveState.watchHomeEventLoggingEnabled = true
        liveState.watchOpponentEventLoggingEnabled = true

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": matchID.uuidString,
            "teamName": "Midline"
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.activeMatchID, matchID)
        XCTAssertEqual(liveState.teamName, "Midline")
        XCTAssertTrue(liveState.trackedEventTypes.isEmpty)
        XCTAssertFalse(liveState.watchHomeEventLoggingEnabled)
        XCTAssertFalse(liveState.watchOpponentEventLoggingEnabled)
        XCTAssertFalse(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateTreatsFinishedMatchAsNotLive() {
        let liveState = WatchLiveState()
        liveState.watchHomeEventLoggingEnabled = true
        liveState.watchOpponentEventLoggingEnabled = true

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "isLive": true,
            "isFinished": true,
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": true
        ])

        XCTAssertTrue(applied)
        XCTAssertFalse(liveState.isLive)
        XCTAssertTrue(liveState.isFinished)
        XCTAssertFalse(liveState.watchHomeEventLoggingEnabled)
        XCTAssertFalse(liveState.watchOpponentEventLoggingEnabled)
        XCTAssertTrue(liveState.availableLoggingTeamSides.isEmpty)
        XCTAssertFalse(liveState.canLogEventsForSelectedTeam)
    }

    func testWatchLiveStateClearsDeliveryMessageWhenMatchFinishes() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID
        liveState.deliveryState = .sending("Goal")
        liveState.recentEvents = [.init(eventType: .goal, teamSide: .home)]

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": matchID.uuidString,
            "isLive": true,
            "isFinished": true
        ])

        XCTAssertTrue(applied)
        XCTAssertFalse(liveState.isLive)
        XCTAssertTrue(liveState.isFinished)
        XCTAssertEqual(liveState.deliveryState, .idle)
        XCTAssertEqual(liveState.recentEvents.map(\.eventType), [.goal])
    }

    func testWatchLiveStateUsesSharedPeriodLabels() {
        let liveState = WatchLiveState()

        liveState.currentHalf = 3
        XCTAssertEqual(liveState.currentHalfTitle, "Extra Time 1")
        XCTAssertEqual(liveState.currentHalfShortTitle, "ET1")

        liveState.currentHalf = 99
        XCTAssertEqual(liveState.currentHalfTitle, "Extra Time 2")
        XCTAssertEqual(liveState.currentHalfShortTitle, "ET2")
    }

    func testWatchLiveStateClampsIncomingPeriod() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "half": 99
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.currentHalf, 4)
        XCTAssertEqual(liveState.currentHalfTitle, "Extra Time 2")
    }

    func testWatchLiveStateClampsIncomingPeriodToMatchTotalPeriods() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "half": 99,
            "totalPeriods": 2,
            "extraTimeEnabled": false
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.totalPeriods, 2)
        XCTAssertEqual(liveState.currentHalf, 2)
        XCTAssertEqual(liveState.currentHalfTitle, "2nd Half")
        XCTAssertEqual(liveState.currentHalfShortTitle, "H2")
    }

    func testWatchLiveStateAppliesExtraTimeMetadata() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "half": 3,
            "totalPeriods": 4,
            "extraTimeEnabled": true,
            "extraTimeHalfDurationMinutes": 18
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.totalPeriods, 4)
        XCTAssertTrue(liveState.extraTimeEnabled)
        XCTAssertEqual(liveState.extraTimeHalfDurationMinutes, 18)
        XCTAssertEqual(liveState.currentHalfTitle, "Extra Time 1")
        XCTAssertEqual(liveState.currentHalfShortTitle, "ET1")
    }

    func testWatchLiveStateAppliesShootoutAndSubstitutionMetadata() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "teamName": "Midline",
            "opponentName": "Rivals",
            "homeScore": 1,
            "awayScore": 1,
            "shootoutStatus": PenaltyShootoutStatus.inProgress.rawValue,
            "homePenaltyScore": 4,
            "awayPenaltyScore": 3,
            "substitutionLimitMode": SubstitutionLimitMode.limited.rawValue,
            "substitutionLimit": 5,
            "homeSubstitutionCount": 5,
            "opponentSubstitutionCount": 2,
            "trackedEventTypes": [
                MatchEventType.goal.rawValue,
                MatchEventType.substitution.rawValue
            ],
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": true
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.currentHalfTitle, "Penalty Kicks")
        XCTAssertEqual(liveState.currentHalfShortTitle, "P")
        XCTAssertEqual(liveState.scoreLine, "Midline 1-1 Rivals (4-3 pens)")
        XCTAssertEqual(liveState.remainingSubstitutions(for: .home), 0)
        XCTAssertEqual(liveState.remainingSubstitutions(for: .opponent), 3)
        XCTAssertFalse(liveState.canSend(.goal))
        XCTAssertFalse(liveState.canSend(.substitution))
    }

    func testWatchLiveStateDisablesOnlyExhaustedSubstitutionActionOutsideShootout() {
        let liveState = WatchLiveState()

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": UUID().uuidString,
            "substitutionLimitMode": SubstitutionLimitMode.limited.rawValue,
            "substitutionLimit": 1,
            "homeSubstitutionCount": 1,
            "trackedEventTypes": [
                MatchEventType.goal.rawValue,
                MatchEventType.substitution.rawValue
            ],
            "watchHomeEventLoggingEnabled": true,
            "watchOpponentEventLoggingEnabled": true
        ])

        XCTAssertTrue(applied)
        XCTAssertTrue(liveState.canSend(.goal))
        XCTAssertFalse(liveState.canSend(.substitution))
        liveState.selectedTeamSide = .opponent
        XCTAssertTrue(liveState.canSend(.substitution))
    }

    func testWatchLiveStateRejectsMalformedActiveMatchContextWithoutMutating() {
        let currentMatchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = currentMatchID
        liveState.teamName = "Current"
        liveState.homeScore = 1

        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "teamName": "Broken",
            "homeScore": 9
        ])

        XCTAssertFalse(applied)
        XCTAssertEqual(liveState.activeMatchID, currentMatchID)
        XCTAssertEqual(liveState.teamName, "Current")
        XCTAssertEqual(liveState.homeScore, 1)
    }

    func testWatchLiveStateResetsMatchDetailsWhenMatchIDChanges() {
        let liveState = WatchLiveState()
        liveState.activeMatchID = UUID()
        liveState.teamName = "Old Home"
        liveState.opponentName = "Old Away"
        liveState.homeScore = 4
        liveState.awayScore = 2
        liveState.currentHalf = 3
        liveState.elapsedSeconds = 720
        liveState.isLive = true
        liveState.trackedEventTypes = [.goal]
        liveState.watchHomeEventLoggingEnabled = true
        liveState.watchOpponentEventLoggingEnabled = true
        liveState.recentEvents = [.init(eventType: .goal, teamSide: .home)]
        liveState.deliveryState = .sent("Goal")

        let newMatchID = UUID()
        let applied = liveState.apply(context: [
            "hasActiveMatch": true,
            "matchID": newMatchID.uuidString
        ])

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.activeMatchID, newMatchID)
        XCTAssertEqual(liveState.teamName, "Home")
        XCTAssertEqual(liveState.opponentName, "Opponent")
        XCTAssertEqual(liveState.homeScore, 0)
        XCTAssertEqual(liveState.awayScore, 0)
        XCTAssertEqual(liveState.currentHalf, 1)
        XCTAssertEqual(liveState.elapsedSeconds, 0)
        XCTAssertFalse(liveState.isLive)
        XCTAssertTrue(liveState.trackedEventTypes.isEmpty)
        XCTAssertFalse(liveState.watchHomeEventLoggingEnabled)
        XCTAssertFalse(liveState.watchOpponentEventLoggingEnabled)
        XCTAssertTrue(liveState.recentEvents.isEmpty)
        XCTAssertEqual(liveState.deliveryState, .idle)
    }

    func testWatchLiveStateClearsMatchFromContext() {
        let liveState = WatchLiveState()
        liveState.activeMatchID = UUID()
        liveState.teamName = "Midline"
        liveState.recentEvents = [.init(eventType: .goal, teamSide: .home)]
        liveState.deliveryState = .sent("Goal")

        let applied = liveState.apply(context: ["hasActiveMatch": false])

        XCTAssertTrue(applied)
        XCTAssertNil(liveState.activeMatchID)
        XCTAssertEqual(liveState.teamName, "No Match")
        XCTAssertTrue(liveState.recentEvents.isEmpty)
        XCTAssertEqual(liveState.deliveryState, .idle)
    }

    func testWatchLiveStateAppliesDeliveryResultForCurrentMatch() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID

        let applied = liveState.applyDeliveryResult(
            .accepted(WatchMatchSnapshot(homeScore: -2, awayScore: -1, elapsedSeconds: -410)),
            eventType: .goal,
            teamSide: .home,
            matchID: matchID
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(liveState.homeScore, 0)
        XCTAssertEqual(liveState.awayScore, 0)
        XCTAssertEqual(liveState.elapsedSeconds, 0)
        XCTAssertEqual(liveState.recentEvents.map(\.eventType), [.goal])
        XCTAssertEqual(liveState.deliveryState, .sent("Goal"))
    }

    func testWatchLiveStateSanitizesDeliveryFailureMessages() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID

        let blankApplied = liveState.applyDeliveryResult(
            .failed(" \n\t "),
            eventType: .goal,
            teamSide: .home,
            matchID: matchID
        )
        let multilineApplied = liveState.applyDeliveryResult(
            .rejected(" Match\nlogging\tis unavailable. "),
            eventType: .goal,
            teamSide: .home,
            matchID: matchID
        )

        XCTAssertTrue(blankApplied)
        XCTAssertTrue(multilineApplied)
        XCTAssertEqual(liveState.deliveryState, .failed("Match logging is unavailable."))

        let secondLiveState = WatchLiveState()
        secondLiveState.activeMatchID = matchID
        _ = secondLiveState.applyDeliveryResult(
            .failed(" \n\t "),
            eventType: .goal,
            teamSide: .home,
            matchID: matchID
        )
        XCTAssertEqual(secondLiveState.deliveryState, .failed("Event could not be sent."))
    }

    func testWatchLiveStateIgnoresStaleDeliveryResultForPreviousMatch() {
        let previousMatchID = UUID()
        let currentMatchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = currentMatchID
        liveState.homeScore = 1
        liveState.awayScore = 0

        let applied = liveState.applyDeliveryResult(
            .accepted(WatchMatchSnapshot(homeScore: 4, awayScore: 3, elapsedSeconds: 700)),
            eventType: .goal,
            teamSide: .home,
            matchID: previousMatchID
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(liveState.homeScore, 1)
        XCTAssertEqual(liveState.awayScore, 0)
        XCTAssertTrue(liveState.recentEvents.isEmpty)
        XCTAssertEqual(liveState.deliveryState, .idle)
    }

    func testWatchLiveStateIgnoresDeliveryResultAfterMatchFinishes() {
        let matchID = UUID()
        let liveState = WatchLiveState()
        liveState.activeMatchID = matchID
        liveState.isFinished = true
        liveState.homeScore = 1
        liveState.awayScore = 0
        liveState.recentEvents = [.init(eventType: .shotOnTarget, teamSide: .home)]
        liveState.deliveryState = .idle

        let applied = liveState.applyDeliveryResult(
            .accepted(WatchMatchSnapshot(homeScore: 2, awayScore: 1, elapsedSeconds: 900)),
            eventType: .goal,
            teamSide: .home,
            matchID: matchID
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(liveState.homeScore, 1)
        XCTAssertEqual(liveState.awayScore, 0)
        XCTAssertEqual(liveState.recentEvents.map(\.eventType), [.shotOnTarget])
        XCTAssertEqual(liveState.deliveryState, .idle)
    }

    func testWatchEventMessageRejectsWhenRequiredPlayerSelectionCannotBeProvided() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        let player = PlayerRecord(name: "Scorer", teamSide: .home, match: match)
        match.players.append(player)
        var quickActions = QuickActionConfiguration()
        quickActions.playerTrackingMode = .required
        let settings = AppSettingsRecord(quickActions: quickActions)
        context.insert(match)
        context.insert(player)
        context.insert(settings)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "rejected")
        XCTAssertEqual(reply["reason"] as? String, "Player selection is required for this match. Log this event from iPhone.")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertTrue(match.events.isEmpty)
    }

    func testWatchEventMessageIgnoresInvalidRawTeamPlayersForRequiredTracking() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        let player = PlayerRecord(name: "Legacy Player", teamSide: .home, match: match)
        player.teamSideRawValue = "visitor"
        match.players.append(player)
        var quickActions = QuickActionConfiguration()
        quickActions.playerTrackingMode = .required
        let settings = AppSettingsRecord(quickActions: quickActions)
        context.insert(match)
        context.insert(player)
        context.insert(settings)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.home.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(match.homeScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
        XCTAssertNil(match.events.first?.playerID)
    }

    func testWatchEventMessageAcceptsRequiredTrackingWhenSelectedSideHasNoPlayers() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        let homePlayer = PlayerRecord(name: "Home Player", teamSide: .home, match: match)
        match.players.append(homePlayer)
        var quickActions = QuickActionConfiguration()
        quickActions.playerTrackingMode = .required
        let settings = AppSettingsRecord(quickActions: quickActions)
        context.insert(match)
        context.insert(homePlayer)
        context.insert(settings)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: match)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let reply = syncService.handleEventMessage([
            "matchID": match.id.uuidString,
            "eventType": MatchEventType.goal.rawValue,
            "teamSide": TeamSide.opponent.rawValue
        ])

        XCTAssertEqual(reply["status"] as? String, "accepted")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 1)
        XCTAssertEqual(match.events.map(\.eventType), [.goal])
    }

    func testApplicationContextPayloadIncludesWatchHapticsPreference() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal, .shotOnTarget])
        match.trackedEventTypeRawValues = [
            MatchEventType.assist.rawValue,
            MatchEventType.goal.rawValue,
            MatchEventType.foulWon.rawValue,
            MatchEventType.shotOnTarget.rawValue
        ]
        var quickActions = QuickActionConfiguration()
        quickActions.watchHapticsEnabled = false
        let settings = AppSettingsRecord(quickActions: quickActions)
        context.insert(match)
        context.insert(settings)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["watchHapticsEnabled"] as? Bool, false)
        XCTAssertEqual(payload["trackedEventTypes"] as? [String], [
            MatchEventType.goal.rawValue,
            MatchEventType.shotOnTarget.rawValue
        ])
    }

    func testApplicationContextPayloadClampsPeriodForWatch() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.currentHalf = 99
        match.homeScore = -2
        match.awayScore = -1
        match.elapsedSeconds = -9
        context.insert(match)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["half"] as? Int, 2)
        XCTAssertEqual(payload["totalPeriods"] as? Int, 2)
        XCTAssertEqual(payload["extraTimeEnabled"] as? Bool, false)
        XCTAssertEqual(payload["extraTimeHalfDurationMinutes"] as? Int, 15)
        XCTAssertEqual(payload["homeScore"] as? Int, 0)
        XCTAssertEqual(payload["awayScore"] as? Int, 0)
        XCTAssertEqual(payload["elapsedSeconds"] as? Int, 0)
    }

    func testApplicationContextPayloadIncludesExtraTimeStateForWatch() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.extraTimeEnabled = true
        match.numberOfHalves = 4
        match.extraTimeHalfDurationMinutes = 18
        match.currentHalf = 3
        context.insert(match)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["half"] as? Int, 3)
        XCTAssertEqual(payload["totalPeriods"] as? Int, 4)
        XCTAssertEqual(payload["extraTimeEnabled"] as? Bool, true)
        XCTAssertEqual(payload["extraTimeHalfDurationMinutes"] as? Int, 18)
    }

    func testApplicationContextPayloadIncludesShootoutAndSubstitutionStateForWatch() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal, .substitution])
        match.homeScore = 1
        match.awayScore = 1
        match.shootoutStatus = .inProgress
        match.homePenaltyScore = 2
        match.awayPenaltyScore = 1
        match.substitutionLimitMode = .limited
        match.substitutionLimit = 3
        context.insert(match)

        let substitution = MatchEventRecord(
            timestamp: Date(timeIntervalSince1970: 269),
            matchMinute: 50,
            period: .secondHalf,
            eventType: .substitution,
            teamSide: .home,
            match: match
        )
        match.events.append(substitution)
        context.insert(substitution)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["shootoutStatus"] as? String, PenaltyShootoutStatus.inProgress.rawValue)
        XCTAssertEqual(payload["homePenaltyScore"] as? Int, 2)
        XCTAssertEqual(payload["awayPenaltyScore"] as? Int, 1)
        XCTAssertEqual(payload["substitutionLimitMode"] as? String, SubstitutionLimitMode.limited.rawValue)
        XCTAssertEqual(payload["substitutionLimit"] as? Int, 3)
        XCTAssertEqual(payload["homeSubstitutionCount"] as? Int, 1)
        XCTAssertEqual(payload["opponentSubstitutionCount"] as? Int, 0)
        XCTAssertEqual(payload["watchHomeEventLoggingEnabled"] as? Bool, false)
        XCTAssertEqual(payload["watchOpponentEventLoggingEnabled"] as? Bool, false)
    }

    func testApplicationContextPayloadTreatsFinishedMatchAsNotLive() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.isLive = true
        match.isFinished = true
        context.insert(match)
        try context.save()

        let payload = MatchSyncService().applicationContextPayload(for: match)

        XCTAssertEqual(payload["isLive"] as? Bool, false)
        XCTAssertEqual(payload["isFinished"] as? Bool, true)
        XCTAssertEqual(payload["watchHomeEventLoggingEnabled"] as? Bool, false)
        XCTAssertEqual(payload["watchOpponentEventLoggingEnabled"] as? Bool, false)
    }

    func testApplicationContextPayloadUsesDisplaySafeTeamNames() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        match.teamName = " "
        match.opponentName = "\n"
        context.insert(match)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["teamName"] as? String, "Home")
        XCTAssertEqual(payload["opponentName"] as? String, "Opponent")
    }

    func testApplicationContextPayloadDisablesWatchLoggingByRosterSideWhenPlayersAreRequired() throws {
        let context = try makeContext()
        let match = makeMatch(trackedEventTypes: [.goal])
        let homePlayer = PlayerRecord(name: "Home Player", teamSide: .home, match: match)
        match.players.append(homePlayer)
        var quickActions = QuickActionConfiguration()
        quickActions.playerTrackingMode = .required
        let settings = AppSettingsRecord(quickActions: quickActions)
        context.insert(match)
        context.insert(homePlayer)
        context.insert(settings)
        try context.save()

        let syncService = MatchSyncService()
        syncService.context = context

        let payload = syncService.applicationContextPayload(for: match)

        XCTAssertEqual(payload["watchHomeEventLoggingEnabled"] as? Bool, false)
        XCTAssertEqual(payload["watchOpponentEventLoggingEnabled"] as? Bool, true)
    }

    func testApplicationContextPayloadMarksActiveAndClearedStates() throws {
        let match = makeMatch()
        let syncService = MatchSyncService()

        XCTAssertEqual(syncService.applicationContextPayload(for: match)["hasActiveMatch"] as? Bool, true)
        XCTAssertEqual(syncService.clearedApplicationContextPayload()["hasActiveMatch"] as? Bool, false)
    }

    func testSyncServiceRestoresLatestUnfinishedMatchFromStore() throws {
        let context = try makeContext()
        let older = makeMatch()
        older.date = Date(timeIntervalSince1970: 100)
        let latestFinished = makeMatch()
        latestFinished.date = Date(timeIntervalSince1970: 300)
        latestFinished.isFinished = true
        let latestUnfinished = makeMatch()
        latestUnfinished.date = Date(timeIntervalSince1970: 200)
        context.insert(older)
        context.insert(latestFinished)
        context.insert(latestUnfinished)
        try context.save()

        let engine = MatchEngine()
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let restored = syncService.restoreActiveMatchFromStore()

        XCTAssertEqual(restored?.id, latestUnfinished.id)
        XCTAssertEqual(engine.activeMatch?.id, latestUnfinished.id)
    }

    func testSyncServiceRestoreNormalizesMatchWithoutResumingPausedMatch() throws {
        let context = try makeContext()
        let match = makeMatch()
        match.isLive = false
        match.durationMinutes = 999
        match.numberOfHalves = 99
        match.currentHalf = 99
        match.elapsedSeconds = -9
        match.homeScore = -2
        match.awayScore = -3
        let player = PlayerRecord(
            name: "Fallback",
            jerseyNumber: 7,
            isStarter: false,
            teamSide: .home,
            match: match
        )
        match.players.append(player)
        context.insert(match)
        context.insert(player)
        try context.save()

        let engine = MatchEngine()
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let restored = syncService.restoreActiveMatchFromStore()

        XCTAssertEqual(restored?.id, match.id)
        XCTAssertEqual(engine.activeMatch?.id, match.id)
        XCTAssertFalse(match.isLive)
        XCTAssertFalse(match.isFinished)
        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(player.isStarter)

        context.rollback()

        XCTAssertFalse(match.isLive)
        XCTAssertFalse(match.isFinished)
        XCTAssertEqual(match.durationMinutes, 130)
        XCTAssertEqual(match.numberOfHalves, 4)
        XCTAssertEqual(match.currentHalf, 4)
        XCTAssertEqual(match.elapsedSeconds, 0)
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertTrue(player.isStarter)
    }

    func testSyncServiceRestoreKeepsCurrentUnfinishedEngineMatch() throws {
        let context = try makeContext()
        let currentEngineMatch = makeMatch()
        currentEngineMatch.date = Date(timeIntervalSince1970: 100)
        let newerUnfinished = makeMatch()
        newerUnfinished.date = Date(timeIntervalSince1970: 300)
        context.insert(currentEngineMatch)
        context.insert(newerUnfinished)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: currentEngineMatch)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let restored = syncService.restoreActiveMatchFromStore()

        XCTAssertEqual(restored?.id, currentEngineMatch.id)
        XCTAssertEqual(engine.activeMatch?.id, currentEngineMatch.id)
    }

    func testSyncServiceClearsEngineWhenNoUnfinishedMatchExists() throws {
        let context = try makeContext()
        let finished = makeMatch()
        finished.isFinished = true
        context.insert(finished)
        try context.save()

        let engine = MatchEngine()
        engine.select(match: finished)
        let syncService = MatchSyncService()
        syncService.engine = engine
        syncService.context = context

        let restored = syncService.restoreActiveMatchFromStore()

        XCTAssertNil(restored)
        XCTAssertNil(engine.activeMatch)
    }

    func testPreferredActiveMatchUsesCurrentEngineMatchWhenAvailable() {
        let latestByDate = makeMatch()
        latestByDate.date = Date(timeIntervalSince1970: 300)
        let currentEngineMatch = makeMatch()
        currentEngineMatch.date = Date(timeIntervalSince1970: 100)

        let preferred = [latestByDate, currentEngineMatch].preferredActiveMatch(currentActiveMatch: currentEngineMatch)

        XCTAssertEqual(preferred?.id, currentEngineMatch.id)
    }

    func testPreferredActiveMatchFallsBackToLatestUnfinishedMatch() {
        let older = makeMatch()
        older.date = Date(timeIntervalSince1970: 100)
        let latestFinished = makeMatch()
        latestFinished.date = Date(timeIntervalSince1970: 300)
        latestFinished.isFinished = true
        let latestUnfinished = makeMatch()
        latestUnfinished.date = Date(timeIntervalSince1970: 200)
        let missingCurrent = makeMatch()

        let preferred = [older, latestFinished, latestUnfinished].preferredActiveMatch(currentActiveMatch: missingCurrent)

        XCTAssertEqual(preferred?.id, latestUnfinished.id)
    }

    func testPreferredActiveMatchPrioritizesLiveMatchOverNewerPausedMatch() {
        let liveMatch = makeMatch()
        liveMatch.date = Date(timeIntervalSince1970: 100)
        liveMatch.isLive = true
        liveMatch.isFinished = false
        let newerPausedMatch = makeMatch()
        newerPausedMatch.date = Date(timeIntervalSince1970: 300)
        newerPausedMatch.isLive = false
        newerPausedMatch.isFinished = false

        let preferred = [newerPausedMatch, liveMatch].preferredActiveMatch(currentActiveMatch: nil)

        XCTAssertEqual(preferred?.id, liveMatch.id)
    }

    func testPreferredActiveMatchUsesStableIDTieBreakForSameDateMatches() {
        let lowerIDMatch = makeMatch()
        lowerIDMatch.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        lowerIDMatch.date = Date(timeIntervalSince1970: 500)
        let higherIDMatch = makeMatch()
        higherIDMatch.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        higherIDMatch.date = lowerIDMatch.date

        let preferred = [lowerIDMatch, higherIDMatch].preferredActiveMatch(currentActiveMatch: nil)

        XCTAssertEqual(preferred?.id, higherIDMatch.id)
    }
    #endif

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            MatchRecord.self,
            MatchEventRecord.self,
            PlayerRecord.self,
            AppSettingsRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func createLegacySQLiteStore(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let matchID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let eventID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let settingsID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let date = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSinceReferenceDate

        try exec("""
        CREATE TABLE ZMATCHRECORD (
            Z_PK INTEGER PRIMARY KEY,
            Z_ENT INTEGER,
            Z_OPT INTEGER,
            ZAWAYSCORE INTEGER,
            ZCURRENTHALF INTEGER,
            ZDURATIONMINUTES INTEGER,
            ZELAPSEDSECONDS INTEGER,
            ZHOMESCORE INTEGER,
            ZISFINISHED INTEGER,
            ZISLIVE INTEGER,
            ZISQUICKMATCH INTEGER,
            ZNUMBEROFHALVES INTEGER,
            ZDATE TIMESTAMP,
            ZACCENTRAWVALUE VARCHAR,
            ZOPPONENTNAME VARCHAR,
            ZTEAMNAME VARCHAR,
            ZTITLE VARCHAR,
            ZID BLOB
        );
        INSERT INTO ZMATCHRECORD (
            Z_PK, Z_ENT, Z_OPT, ZAWAYSCORE, ZCURRENTHALF, ZDURATIONMINUTES, ZELAPSEDSECONDS,
            ZHOMESCORE, ZISFINISHED, ZISLIVE, ZISQUICKMATCH, ZNUMBEROFHALVES, ZDATE,
            ZACCENTRAWVALUE, ZOPPONENTNAME, ZTEAMNAME, ZTITLE, ZID
        ) VALUES (
            1, 1, 1, 1, 2, 80, 4800, 2, 0, 1, 0, 2, \(date),
            'stadiumGreen', 'Old Rivals', 'Legacy FC', 'Legacy Final', X'\(matchID.sqliteHex)'
        );

        CREATE TABLE ZMATCHEVENTRECORD (
            Z_PK INTEGER PRIMARY KEY,
            Z_ENT INTEGER,
            Z_OPT INTEGER,
            ZMATCHMINUTE INTEGER,
            ZMATCH INTEGER,
            ZPITCHX FLOAT,
            ZPITCHY FLOAT,
            ZTIMESTAMP TIMESTAMP,
            ZEVENTTYPERAWVALUE VARCHAR,
            ZNOTES VARCHAR,
            ZPERIODRAWVALUE VARCHAR,
            ZTEAMSIDERAWVALUE VARCHAR,
            ZID BLOB,
            ZLINKEDGROUPID BLOB,
            ZPLAYERID BLOB,
            ZSECONDARYPLAYERID BLOB
        );
        INSERT INTO ZMATCHEVENTRECORD (
            Z_PK, Z_ENT, Z_OPT, ZMATCHMINUTE, ZMATCH, ZTIMESTAMP,
            ZEVENTTYPERAWVALUE, ZPERIODRAWVALUE, ZTEAMSIDERAWVALUE, ZID
        ) VALUES (
            1, 2, 1, 42, 1, \(date), 'goal', 'secondHalf', 'home', X'\(eventID.sqliteHex)'
        );

        CREATE TABLE ZAPPSETTINGSRECORD (
            Z_PK INTEGER PRIMARY KEY,
            Z_ENT INTEGER,
            Z_OPT INTEGER,
            ZDEFAULTDURATIONMINUTES INTEGER,
            ZDEFAULTNUMBEROFHALVES INTEGER,
            ZTHEMEACCENTRAWVALUE VARCHAR,
            ZID BLOB,
            ZQUICKACTIONSDATA BLOB
        );
        INSERT INTO ZAPPSETTINGSRECORD (
            Z_PK, Z_ENT, Z_OPT, ZDEFAULTDURATIONMINUTES, ZDEFAULTNUMBEROFHALVES,
            ZTHEMEACCENTRAWVALUE, ZID, ZQUICKACTIONSDATA
        ) VALUES (
            1, 3, 1, 80, 2, 'matchBlue', X'\(settingsID.sqliteHex)', X''
        );
        """, db: db)
    }

    private func exec(_ sql: String, db: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
            } else {
                message = "Unknown SQLite error"
            }
            sqlite3_free(errorMessage)
            XCTFail(message)
            throw NSError(domain: "MidlineSQLiteTest", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func makeMatch(trackedEventTypes: [MatchEventType] = MatchEventType.defaultQuickActions) -> MatchRecord {
        MatchRecord(
            title: "Midline FC vs Rivals FC",
            teamName: "Midline FC",
            opponentName: "Rivals FC",
            elapsedSeconds: 74,
            trackedEventTypes: trackedEventTypes
        )
    }
}

private extension MatchAnalyticsSummary {
    func value(for title: String) -> Int? {
        teamTotals.first { $0.title == title }?.value
    }
}

private extension UUID {
    var sqliteHex: String {
        withUnsafeBytes(of: uuid) { buffer in
            buffer.map { String(format: "%02X", $0) }.joined()
        }
    }
}
