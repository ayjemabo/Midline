import SwiftUI

struct RootTabView: View {
    @Bindable var engine: MatchEngine

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(engine: engine)
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                HistoryView(engine: engine)
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            NavigationStack {
                SettingsView(engine: engine)
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}
