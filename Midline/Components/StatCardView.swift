import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

