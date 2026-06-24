import SwiftUI
import WatchKit

struct WatchEventGridView: View {
    let title: String
    let events: [MatchEventType]
    @Bindable var liveState: WatchLiveState

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                scoreboard
                teamSidePicker
                Text(title)
                    .font(.headline)

                if events.isEmpty {
                    Text("No enabled actions")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(events, id: \.self) { event in
                            Button {
                                send(event)
                            } label: {
                                Text(event.title)
                                    .font(.footnote.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(event.tint)
                            .disabled(!liveState.canSend(event))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if liveState.activeMatchID == nil {
                Text("No Active Match")
                    .font(.footnote.weight(.semibold))
                Text("Open a live match on iPhone")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(liveState.scoreLine)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text("\(liveState.currentHalfShortTitle) • \(clock)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(liveState.isFinished ? .red : .secondary)
                if let message = liveState.deliveryState.message {
                    Text(message)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(liveState.deliveryState.isFailure ? .red : .green)
                        .lineLimit(2)
                }
                if liveState.isPenaltyShootoutActive {
                    Text("Log penalty kicks on iPhone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if !liveState.canLogEventsForSelectedTeam {
                    Text("Player required on iPhone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if !liveState.canUseSubstitution(for: liveState.selectedTeamSide) {
                    Text("No substitutions remaining")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var teamSidePicker: some View {
        let availableSides = liveState.availableLoggingTeamSides
        if liveState.activeMatchID != nil, !availableSides.isEmpty {
            Picker("Logging For", selection: $liveState.selectedTeamSide) {
                ForEach(availableSides, id: \.self) { teamSide in
                    Text(liveState.name(for: teamSide)).tag(teamSide)
                }
            }
            .labelsHidden()
        }
    }

    private var statusText: String {
        if liveState.isFinished { return "Finished" }
        return liveState.isLive ? "Live" : "Paused"
    }

    private var clock: String {
        liveState.clockText
    }

    private func send(_ event: MatchEventType) {
        guard liveState.canSend(event) else {
            liveState.deliveryState = .failed(disabledSendMessage(for: event))
            playHaptic(.failure)
            return
        }

        guard let matchID = liveState.activeMatchID else {
            liveState.deliveryState = .failed("Open a live match on iPhone first.")
            playHaptic(.failure)
            return
        }

        let teamSide = liveState.selectedTeamSide
        liveState.startSending(event)

        MatchSyncService.shared.sendEvent(event, matchID: matchID, teamSide: teamSide) { result in
            guard liveState.applyDeliveryResult(result, eventType: event, teamSide: teamSide, matchID: matchID) else {
                return
            }
            switch result {
            case .accepted(_):
                playHaptic(.click)
            case .rejected, .failed:
                playHaptic(.failure)
            }
        }
    }

    private func playHaptic(_ type: WKHapticType) {
        guard liveState.watchHapticsEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }

    private func disabledSendMessage(for event: MatchEventType) -> String {
        if liveState.activeMatchID == nil {
            return "Open a live match on iPhone first."
        }
        if liveState.isFinished {
            return "Match is already finished."
        }
        if liveState.deliveryState.isSending {
            return "Sending previous event."
        }
        if liveState.isPenaltyShootoutActive {
            return "Log penalty kicks on iPhone."
        }
        if !liveState.canLogEventsForSelectedTeam {
            return "Player selection is required on iPhone."
        }
        if event == .substitution, !liveState.canUseSubstitution(for: liveState.selectedTeamSide) {
            return "No substitutions remaining."
        }
        return "Event cannot be sent right now."
    }
}
