import SwiftUI

struct ResultRowView: View {
    let result: CompressionResult

    @State private var isHovering = false

    private var tierColor: Color {
        switch result.colorTier {
        case .green: .green
        case .yellow: .yellow
        case .gray: .secondary
        case .red: .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tierColor)
                .frame(width: 8, height: 8)
                .shadow(color: tierColor.opacity(0.5), radius: 2)

            Text(result.filename)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let compressed = result.compressedSize {
                HStack(spacing: 6) {
                    Text(result.originalSize.formattedBytes)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(compressed.formattedBytes)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.caption)

                Text(String(format: "−%.0f%%", result.reduction))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tierColor)
                    .frame(width: 52, alignment: .trailing)
                    .monospacedDigit()
            } else {
                Text(result.error ?? "Failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 18)
        .background(
            Rectangle()
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
