import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \MatchRecord.date, order: .reverse) private var matches: [MatchRecord]
    @Bindable var engine: MatchEngine
    @State private var showingQuickMatch = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                actionGrid
                matchOverview
            }
            .padding()
            .padding(.bottom, 132)
        }
        .navigationTitle("Midline")
        .sheet(isPresented: $showingQuickMatch) {
            NavigationStack {
                MatchSetupView(engine: engine, quickMode: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Middle-detail match tracking")
                .font(.largeTitle.weight(.bold))
            Text("Log events fast during play, then review useful analytics without analyst-tool overhead.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionGrid: some View {
        VStack(spacing: 14) {
            NavigationLink {
                MatchSetupView(engine: engine)
            } label: {
                homeActionCard(title: "Start New Match", subtitle: "Full setup with players and tracked actions", systemImage: "plus.circle.fill")
            }

            Button {
                showingQuickMatch = true
            } label: {
                homeActionCard(title: "Quick Match", subtitle: "Team, opponent, and kickoff in seconds", systemImage: "bolt.fill")
            }

            if let active = activeMatch {
                NavigationLink {
                    LiveMatchView(match: active, engine: engine)
                } label: {
                    homeActionCard(title: "Resume Current Match", subtitle: resumeSubtitle(for: active), systemImage: "play.circle.fill")
                }
            }

            NavigationLink {
                HistoryView(engine: engine)
            } label: {
                homeActionCard(title: "View Past Matches", subtitle: "Search and review match summaries", systemImage: "list.bullet.rectangle")
            }
        }
        .buttonStyle(.plain)
    }

    private var activeMatch: MatchRecord? {
        matches.preferredActiveMatch(currentActiveMatch: engine.activeMatch)
    }

    private func resumeSubtitle(for match: MatchRecord) -> String {
        let status = match.isLive ? "Live" : "Paused"
        let clock = MatchFormat.clockText(forElapsedSeconds: match.elapsedClockSeconds)
        return "\(status) • \(match.compactScoreLine) • \(match.currentHalfTitle) \(clock)"
    }

    @ViewBuilder
    private var matchOverview: some View {
        if matches.isEmpty {
            firstRunState
        } else if let activeMatch {
            currentMatchState(activeMatch)
        } else {
            lastMatchSummary
        }
    }

    private var firstRunState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No matches yet", systemImage: "sportscourt")
                .font(.title3.weight(.semibold))
            Text("Start a setup or quick match to begin tracking.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var lastMatchSummary: some View {
        Group {
            if let lastFinished = matches.first(where: \.isFinished) {
                let summary = MatchAnalyticsService().buildSummary(for: lastFinished)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Last Match Summary")
                        .font(.title3.weight(.semibold))
                    Text(summary.scoreLine)
                        .font(.headline)

                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                        StatCardView(title: "Attack Involvement", value: "\(summary.attackInvolvement)", accent: .green)
                        StatCardView(title: "Defensive Involvement", value: "\(summary.defensiveInvolvement)", accent: .blue)
                        StatCardView(title: "Discipline", value: "\(summary.discipline)", accent: .orange)
                        StatCardView(title: "Retention Impact", value: "\(summary.ballRetentionImpact)", accent: .pink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No completed matches yet", systemImage: "chart.bar")
                        .font(.title3.weight(.semibold))
                    Text("Finish a match to unlock the summary cards here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private func currentMatchState(_ match: MatchRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(match.isLive ? "Match in progress" : "Match paused", systemImage: match.isLive ? "play.circle.fill" : "pause.circle.fill")
                .font(.title3.weight(.semibold))
            Text(match.compactScoreLine)
                .font(.headline)
            Text("\(match.currentHalfTitle) • \(MatchFormat.clockText(forElapsedSeconds: match.elapsedClockSeconds))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func homeActionCard(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
