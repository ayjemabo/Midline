import SwiftUI

struct ScoreboardHeaderView: View {
    let match: MatchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(match.displayTitle.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text("\(match.displayTeamName) vs \(match.displayOpponentName)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(currentClock)
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(match.currentHalfTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(match.accent.color.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 14) {
                homeTeamPanel
                Spacer()
                versusBadge
                Spacer()
                awayTeamPanel
            }

            if match.hasPenaltyShootout {
                Text("Penalties \(match.homePenaltyScoreValue)-\(match.awayPenaltyScoreValue)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .foregroundStyle(.primary)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(match.accent.color.opacity(0.18))
        )
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(match.accent.color)
                .frame(width: 76, height: 5)
                .clipShape(Capsule())
                .padding(.top, 10)
                .padding(.leading, 18)
        }
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    }

    private var currentClock: String {
        MatchFormat.clockText(forElapsedSeconds: match.elapsedClockSeconds)
    }

    private var homeTeamPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(match.displayTeamName)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text("\(match.homeScoreValue)")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var awayTeamPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(match.displayOpponentName)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.trailing)
            Text("\(match.awayScoreValue)")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var versusBadge: some View {
        Text("VS")
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(match.accent.color.opacity(0.10), in: Capsule())
    }

    private var cardBackground: some ShapeStyle {
        Color(uiColor: .secondarySystemBackground)
    }
}
