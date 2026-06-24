import SwiftUI

@main
struct MidlineWatchApp: App {
    @State private var liveState = WatchLiveState()

    var body: some Scene {
        WindowGroup {
            WatchRootView(liveState: liveState)
                .task {
                    MatchSyncService.shared.configureWatch { applicationContext in
                        liveState.apply(context: applicationContext)
                    }
                }
        }
    }
}
