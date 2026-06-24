import Foundation
import SwiftData

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@MainActor
final class MatchSyncService: NSObject {
    static let shared = MatchSyncService()

    var engine: MatchEngine?
    var context: ModelContext?
    var watchContextHandler: (([String: Any]) -> Void)?

    func configure(engine: MatchEngine, context: ModelContext) {
        self.engine = engine
        self.context = context
        restoreActiveMatchFromStore()
        activate()
        broadcastConfiguredMatchState()
    }

    func configureWatch(contextHandler: @escaping ([String: Any]) -> Void) {
        self.watchContextHandler = contextHandler
        activate()
        applyCachedWatchApplicationContextIfNeeded()
    }

    @discardableResult
    func sendEvent(
        _ eventType: MatchEventType,
        matchID: UUID,
        teamSide: TeamSide = .home,
        completion: ((WatchEventDeliveryResult) -> Void)? = nil
    ) -> Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.default.isReachable else {
            completion?(.failed("iPhone is not reachable."))
            return false
        }
        WCSession.default.sendMessage([
            "matchID": matchID.uuidString,
            "eventType": eventType.rawValue,
            "teamSide": teamSide.rawValue
        ], replyHandler: { reply in
            Task { @MainActor in
                completion?(Self.deliveryResult(from: reply))
            }
        }, errorHandler: { error in
            Task { @MainActor in
                completion?(.failed(error.localizedDescription))
            }
        })
        return true
        #else
        completion?(.failed("Watch sync is unavailable."))
        return false
        #endif
    }

    func broadcastMatchState(_ match: MatchRecord) {
        #if canImport(WatchConnectivity)
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(applicationContextPayload(for: match))
        #endif
    }

    func broadcastClearedMatchState() {
        #if canImport(WatchConnectivity)
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(clearedApplicationContextPayload())
        #endif
    }

    func applicationContextPayload(for match: MatchRecord) -> [String: Any] {
        [
            "hasActiveMatch": true,
            "matchID": match.id.uuidString,
            "teamName": match.displayTeamName,
            "opponentName": match.displayOpponentName,
            "homeScore": match.homeScoreValue,
            "awayScore": match.awayScoreValue,
            "shootoutStatus": match.shootoutStatus.rawValue,
            "homePenaltyScore": match.homePenaltyScoreValue,
            "awayPenaltyScore": match.awayPenaltyScoreValue,
            "substitutionLimitMode": match.substitutionLimitMode.rawValue,
            "substitutionLimit": match.substitutionLimitValue,
            "homeSubstitutionCount": match.substitutionCount(for: .home),
            "opponentSubstitutionCount": match.substitutionCount(for: .opponent),
            "half": match.currentPeriodNumber,
            "totalPeriods": match.totalPeriodNumber,
            "extraTimeEnabled": match.usesExtraTime,
            "extraTimeHalfDurationMinutes": match.extraTimeHalfDurationMinuteValue,
            "elapsedSeconds": match.elapsedClockSeconds,
            "isLive": match.isLive && !match.isFinished,
            "isFinished": match.isFinished,
            "trackedEventTypes": match.trackedEventTypes.map(\.rawValue),
            "watchHapticsEnabled": quickActionConfiguration.watchHapticsEnabled,
            "watchHomeEventLoggingEnabled": allowsWatchLogging(for: .home, in: match),
            "watchOpponentEventLoggingEnabled": allowsWatchLogging(for: .opponent, in: match)
        ]
    }

    func clearedApplicationContextPayload() -> [String: Any] {
        [
            "hasActiveMatch": false
        ]
    }

    @discardableResult
    func restoreActiveMatchFromStore() -> MatchRecord? {
        guard let engine, let context else { return nil }

        let descriptor = FetchDescriptor<MatchRecord>(
            predicate: #Predicate { !$0.isFinished },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )

        guard
            let matches = try? context.fetch(descriptor),
            let match = matches.preferredActiveMatch(currentActiveMatch: engine.activeMatch)
        else {
            engine.activeMatch = nil
            return nil
        }

        engine.restore(match: match)
        do {
            try context.save()
        } catch {
            context.rollback()
        }
        return match
    }

    private func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }

    private func applyCachedWatchApplicationContextIfNeeded() {
        #if canImport(WatchConnectivity)
        let applicationContext = WCSession.default.receivedApplicationContext
        guard !applicationContext.isEmpty else { return }
        applyWatchApplicationContext(applicationContext)
        #endif
    }

    func applyWatchApplicationContext(_ applicationContext: [String: Any]) {
        watchContextHandler?(applicationContext)
    }

    private var quickActionConfiguration: QuickActionConfiguration {
        guard let context else { return .init() }
        let descriptor = FetchDescriptor<AppSettingsRecord>()
        guard let settings = try? context.fetch(descriptor).preferredSettingsRecord else { return .init() }
        return settings.quickActions
    }

    private func allowsWatchLogging(for teamSide: TeamSide, in match: MatchRecord) -> Bool {
        guard !match.isFinished, !match.isPenaltyShootoutActive else { return false }
        return quickActionConfiguration.playerTrackingMode != .required
        || !match.players.contains { $0.validTeamSide == teamSide }
    }

    private func broadcastConfiguredMatchState() {
        guard let engine else { return }
        if let activeMatch = engine.activeMatch {
            broadcastMatchState(activeMatch)
        } else {
            broadcastClearedMatchState()
        }
    }
}

enum WatchEventDeliveryResult: Equatable {
    case accepted(WatchMatchSnapshot?)
    case rejected(String)
    case failed(String)
}

struct WatchMatchSnapshot: Equatable {
    var homeScore: Int?
    var awayScore: Int?
    var elapsedSeconds: Int?
}

#if canImport(WatchConnectivity)
extension MatchSyncService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        #if os(iOS)
        guard activationState == .activated else { return }
        broadcastConfiguredMatchState()
        #endif
    }
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        _ = handleEventMessage(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        replyHandler(handleEventMessage(message))
    }

    func handleEventMessage(_ message: [String: Any]) -> [String: Any] {
        guard
            let matchIDString = message["matchID"] as? String,
            let eventTypeRawValue = message["eventType"] as? String,
            let teamSideRawValue = message["teamSide"] as? String,
            let matchID = UUID(uuidString: MatchFormat.sanitizedRawValue(matchIDString)),
            let eventType = MatchEventType(rawValue: MatchFormat.sanitizedRawValue(eventTypeRawValue)),
            let teamSide = TeamSide(rawValue: MatchFormat.sanitizedRawValue(teamSideRawValue))
        else {
            return Self.rejectedReply("Invalid event payload.")
        }
        guard let engine, let context else {
            return Self.rejectedReply("Match logging is not ready.")
        }
        guard engine.activeMatch?.id == matchID else {
            return Self.rejectedReply("Match is no longer active.")
        }

        let descriptor = FetchDescriptor<MatchRecord>(predicate: #Predicate { $0.id == matchID })
        guard let match = try? context.fetch(descriptor).first else {
            return Self.rejectedReply("Match is no longer available.")
        }

        guard !match.isFinished else {
            return Self.rejectedReply("Match is already finished.")
        }
        guard !match.isPenaltyShootoutActive else {
            return Self.rejectedReply(MatchEngineError.shootoutActive.localizedDescription)
        }
        guard match.trackedEventTypes.contains(eventType), eventType != .foulWon else {
            return Self.rejectedReply("\(eventType.title) is not enabled for this match.")
        }
        guard allowsWatchLogging(for: teamSide, in: match) else {
            return Self.rejectedReply("Player selection is required for this match. Log this event from iPhone.")
        }

        do {
            try engine.log(eventType: eventType, in: match, context: context, teamSide: teamSide, source: .watch)
            broadcastMatchState(match)
            return [
                "status": "accepted",
                "homeScore": match.homeScoreValue,
                "awayScore": match.awayScoreValue,
                "elapsedSeconds": match.elapsedClockSeconds
            ]
        } catch {
            context.rollback()
            return Self.rejectedReply(error.localizedDescription)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in
            applyWatchApplicationContext(applicationContext)
        }
    }

    static func deliveryResult(from reply: [String: Any]) -> WatchEventDeliveryResult {
        guard let status = reply["status"] as? String else {
            return .rejected("iPhone sent an unreadable reply.")
        }

        if MatchFormat.sanitizedRawValue(status) == "accepted" {
            return .accepted(WatchMatchSnapshot(
                homeScore: (reply["homeScore"] as? Int).map(MatchFormat.clampedScore),
                awayScore: (reply["awayScore"] as? Int).map(MatchFormat.clampedScore),
                elapsedSeconds: (reply["elapsedSeconds"] as? Int).map(MatchFormat.clampedElapsedSeconds)
            ))
        }

        let reason = MatchFormat.singleLineDisplayText(
            reply["reason"] as? String,
            fallback: "iPhone could not save the event."
        )
        return .rejected(reason)
    }

    private static func rejectedReply(_ reason: String) -> [String: Any] {
        [
            "status": "rejected",
            "reason": reason
        ]
    }
}
#endif
