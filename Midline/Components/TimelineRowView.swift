import SwiftUI

struct TimelineRowView: View {
    let event: MatchEventRecord
    let detailText: String?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(event.matchMinuteValue)'")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Circle()
                .fill(event.validEventType?.tint ?? .secondary)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayTitle)
                    .font(.headline)
                if let detailText {
                    Text(detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let period = event.validPeriod {
                Text(period.shortTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }
}
