import SwiftUI

struct WatchMatchControlsView: View {
    @Bindable var liveState: WatchLiveState

    var body: some View {
        List {
            if liveState.activeMatchID == nil {
                Section("Live") {
                    Text("No Active Match")
                        .font(.headline)
                    Text("Open a live match on iPhone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Live") {
                    Text(liveState.scoreLine)
                    Text(liveState.currentHalfTitle)
                    Text(clock)
                        .monospacedDigit()
                    if liveState.isPenaltyShootoutActive {
                        Text("Log penalty kicks on iPhone")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Recent Events") {
                if liveState.recentEvents.isEmpty {
                    Text("No recent events")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(liveState.recentEvents) { event in
                        VStack(alignment: .leading) {
                            Text(event.eventType.title)
                            Text(liveState.name(for: event.teamSide))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if liveState.activeMatchID != nil {
                Section("Controls") {
                    Text("Undo from iPhone")
                    Text("Period / end controls handled by sync host")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clock: String {
        liveState.clockText
    }
}
