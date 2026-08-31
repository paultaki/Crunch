import CrunchCore
import SwiftUI

struct ResultRowView: View {
    let result: CompressionResult

    @State private var isHovering = false

    private var tierColor: Color {
        switch result.colorTier {
        case .green: .green
        case .yellow: .yellow
        case .gray: .secondary
        case .skipped: .secondary
        case .grew: .orange
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

            if result.wasSkipped {
                Text("Already optimized")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let compressed = result.compressedSize {
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

                reductionLabel
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

    /// Reduction badge. `reduction` is negative when a format conversion
    /// grew the file (the only case that reaches here with a negative
    /// value — the never-worse guard skips same-format growth entirely).
    /// Branching on sign rather than hardcoding a "−" prefix keeps the
    /// double-minus bug ("−-12%") impossible by construction (mirrors
    /// `EstimatePreviewView`'s trailingBadge).
    @ViewBuilder
    private var reductionLabel: some View {
        if result.reduction >= 0 {
            Text(String(format: "−%.0f%%", result.reduction))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tierColor)
                .frame(width: 52, alignment: .trailing)
                .monospacedDigit()
        } else {
            Text(String(format: "+%.0f%%", -result.reduction))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 52, alignment: .trailing)
                .monospacedDigit()
        }
    }
}
