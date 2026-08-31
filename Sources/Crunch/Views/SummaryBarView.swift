import SwiftUI

struct SummaryBarView: View {
    let fileCount: Int
    let originalSize: Int64
    let compressedSize: Int64
    let reduction: Double

    private var savedBytes: Int64 { max(0, originalSize - compressedSize) }

    var body: some View {
        HStack(spacing: 20) {
            metric(
                label: "Saved",
                value: savedBytes.formattedBytes,
                tint: .green,
                emphasised: true
            )

            Divider().frame(height: 28).opacity(0.4)

            metric(
                label: "Original",
                value: originalSize.formattedBytes,
                tint: .secondary
            )

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            metric(
                label: "Compressed",
                value: compressedSize.formattedBytes,
                tint: .primary
            )

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", reduction))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reduction))
                Text("reduction")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func metric(
        label: String,
        value: String,
        tint: Color,
        emphasised: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(emphasised ? .body.weight(.semibold) : .callout)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }
}
