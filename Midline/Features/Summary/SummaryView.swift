import SwiftUI

struct SummaryView: View {
    let match: MatchRecord
    @State private var analyticsScope: MatchAnalyticsScope = .home

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(analytics.scoreLine)
                    .font(.largeTitle.weight(.bold))
                Text(match.formatSummaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Analytics Scope", selection: $analyticsScope) {
                    ForEach(MatchAnalyticsScope.allCases) { scope in
                        Text(scope.segmentedTitle).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    StatCardView(title: "Attack Involvement", value: "\(analytics.attackInvolvement)", accent: .green)
                    StatCardView(title: "Defensive Involvement", value: "\(analytics.defensiveInvolvement)", accent: .blue)
                    StatCardView(title: "Discipline", value: "\(analytics.discipline)", accent: .orange)
                    StatCardView(title: "Retention Impact", value: "\(analytics.ballRetentionImpact)", accent: .pink)
                }

                Text("\(analyticsScope.title(for: match)) Totals")
                    .font(.title3.weight(.semibold))

                ForEach(analytics.teamTotals) { line in
                    HStack {
                        Text(line.title)
                        Spacer()
                        Text("\(line.value)")
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }

                if let top = analytics.mostActivePlayer {
                    playerLeader(title: "Most Active Player", player: top)
                }

                if let topAttacker = analytics.topAttackingContributor {
                    playerLeader(title: "Top Attacking Contributor", player: topAttacker)
                }

                if let topDefender = analytics.topDefensiveContributor {
                    playerLeader(title: "Top Defensive Contributor", player: topDefender)
                }

                Text("Timeline")
                    .font(.title3.weight(.semibold))
                let timelineEvents = scopedTimelineEvents
                if timelineEvents.isEmpty {
                    Text("No events were logged for \(analyticsScope.title(for: match).lowercased()).")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                        .padding(.horizontal, 12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ForEach(timelineEvents) { event in
                        TimelineRowView(
                            event: event,
                            detailText: match.summaryTimelineDetailText(for: event, scope: analyticsScope)
                        )
                    }
                }
            }
            .padding()
            .padding(.bottom, 32)
        }
        .navigationTitle("Summary")
        .toolbar(.hidden, for: .tabBar)
    }

    private var analytics: MatchAnalyticsSummary {
        MatchAnalyticsService().buildSummary(for: match, scope: analyticsScope)
    }

    private func playerLeader(title: String, player: PlayerStatSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(player.playerName)
                .font(.headline)
            Text(teamName(for: player.teamSide))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func teamName(for teamSide: TeamSide) -> String {
        match.displayName(for: teamSide)
    }

    private var scopedTimelineEvents: [MatchEventRecord] {
        match.summaryTimelineEvents(for: analyticsScope)
    }
}
