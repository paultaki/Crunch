import CrunchCore
import SwiftUI

struct SummaryBarView: View {
    let summary: BatchSummary

    var body: some View {
        Group {
            if summary.hasSuccesses {
                savingsMetrics
            } else {
                failureNotice
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

    /// The normal case: at least one file landed, so there are real bytes to
    /// report. Every figure comes from the succeeded results only.
    private var savingsMetrics: some View {
        HStack(spacing: 20) {
            metric(
                label: "Saved",
                value: summary.savedBytes.formattedBytes,
                tint: .green,
                emphasised: true
            )

            Divider().frame(height: 28).opacity(0.4)

            metric(
                label: "Original",
                value: summary.originalSize.formattedBytes,
                tint: .secondary
            )

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            metric(
                label: "Compressed",
                value: summary.compressedSize.formattedBytes,
                tint: .primary
            )

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", summary.reduction))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: summary.reduction))
                Text("reduction")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
        }
    }

    /// Nothing succeeded, so there is nothing to celebrate: no green, no
    /// savings figure, no percentage. Uses the same red the failed result
    /// rows already use rather than inventing a new failure treatment.
    private var failureNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("No files were compressed")
                .font(.body.weight(.semibold))
            Spacer()
            Text("\(summary.failedCount) failed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: 34)
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
