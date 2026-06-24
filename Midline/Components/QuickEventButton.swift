import SwiftUI

struct QuickEventButton: View {
    let eventType: MatchEventType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: eventType.systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(eventType.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(eventType.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
