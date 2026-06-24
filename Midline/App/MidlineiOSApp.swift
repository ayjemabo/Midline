import SwiftUI
import SwiftData

@main
struct MidlineiOSApp: App {
    @State private var engine = MatchEngine()
    @State private var launchErrorMessage: String?
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootTabView(engine: engine)
                .modelContainer(persistence.container)
                .alert("Couldn’t Prepare App", isPresented: Binding(
                    get: { launchErrorMessage != nil },
                    set: { if !$0 { launchErrorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(launchErrorMessage ?? "Try relaunching Midline.")
                }
                .task {
                    let context = persistence.container.mainContext
                    do {
                        try persistence.prepareRequiredRecords(context: context)
                        MatchSyncService.shared.configure(engine: engine, context: context)
                        launchErrorMessage = persistence.launchIssueMessage
                    } catch {
                        launchErrorMessage = error.localizedDescription
                    }
                }
        }
    }
}
