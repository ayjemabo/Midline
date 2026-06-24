import Foundation

enum SampleData {
    static var matches: [MatchRecord] {
        let match = MatchRecord(
            title: "Friday 7-a-side",
            teamName: "Midline FC",
            opponentName: "Northside",
            date: .now.addingTimeInterval(-86_400),
            isQuickMatch: false,
            currentHalf: 2,
            homeScore: 3,
            awayScore: 1,
            elapsedSeconds: 5_100,
            isLive: false,
            isFinished: true
        )

        let players = [
            PlayerRecord(name: "Omar", jerseyNumber: 9, position: .forward, isFavorite: true, isPinned: true, match: match),
            PlayerRecord(name: "Sami", jerseyNumber: 8, position: .midfielder, isFavorite: true, match: match),
            PlayerRecord(name: "Faisal", jerseyNumber: 4, position: .defender, match: match)
        ]

        match.players = players
        match.events = [
            MatchEventRecord(matchMinute: 8, period: .firstHalf, eventType: .goal, playerID: players[0].id, secondaryPlayerID: players[1].id, notes: "Open Play", match: match),
            MatchEventRecord(matchMinute: 16, period: .firstHalf, eventType: .keyPass, playerID: players[1].id, match: match),
            MatchEventRecord(matchMinute: 29, period: .firstHalf, eventType: .tackleWon, playerID: players[2].id, match: match),
            MatchEventRecord(matchMinute: 44, period: .secondHalf, eventType: .shotOnTarget, playerID: players[0].id, match: match),
            MatchEventRecord(matchMinute: 58, period: .secondHalf, eventType: .interception, playerID: players[2].id, match: match),
            MatchEventRecord(matchMinute: 71, period: .secondHalf, eventType: .goal, playerID: players[0].id, match: match)
        ]

        return [match]
    }
}
