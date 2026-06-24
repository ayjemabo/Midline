import SwiftUI

struct WatchRootView: View {
    @Bindable var liveState: WatchLiveState

    var body: some View {
        TabView {
            WatchEventGridView(
                title: "Attack",
                events: liveState.enabledEvents(from: MatchEventType.watchPrimaryGroup),
                liveState: liveState
            )
            WatchEventGridView(
                title: "Defense",
                events: liveState.enabledEvents(from: MatchEventType.watchSecondaryGroup),
                liveState: liveState
            )
            WatchEventGridView(
                title: "More",
                events: liveState.enabledEvents(from: MatchEventType.watchMoreGroup),
                liveState: liveState
            )
            WatchMatchControlsView(liveState: liveState)
        }
        .tabViewStyle(.verticalPage)
    }
}
