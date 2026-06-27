import SwiftUI

struct QuickEventButton: View {
    let eventType: MatchEventType
    var detailAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: eventType.systemImage)
                        .font(.subheadline.weight(.semibold))
                    Text(eventType.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, detailAction == nil ? 14 : 48)
                .padding(.vertical, 12)
                .background(eventType.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let detailAction {
                    Button {
                        detailAction()
                    } label: {
                        Label("Add Details", systemImage: "ellipsis.circle")
                    }
                }
            }

            if let detailAction {
                Button(action: detailAction) {
                    Image(systemName: "ellipsis.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(eventType.tint)
                        .frame(width: 34, height: 34)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("\(eventType.title) Details")
            }
        }
    }
}
