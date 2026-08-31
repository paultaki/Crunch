import CrunchCore
import SwiftUI

/// Shows a live before/after preview of the expected compression result,
/// updating as the user changes format, quality, and resolution. Calls out
/// that the number is an *estimate* (the tilde and label) so the user knows
/// it may drift slightly from the real run.
struct EstimatePreviewView: View {
    let originalSize: Int64
    let estimatedSize: Int64?
    let reduction: Double?
    let isEstimating: Bool
    /// Set when the estimate couldn't run because a required compressor is
    /// missing — shown as an inline install hint instead of a silent "—".
    let missingToolFormat: ImageFormat?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            leadingMetrics

            Spacer(minLength: 8)

            trailingBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - Leading

    private var leadingMetrics: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Estimated Output")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                if isEstimating {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                }
            }

            if let missingToolFormat,
               let hint = MissingToolsMessage.compactInstallHint(for: missingToolFormat) {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    Text(originalSize.formattedBytes)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Group {
                        if let estimated = estimatedSize {
                            Text("~\(estimated.formattedBytes)")
                                .foregroundStyle(.primary)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(estimated)))
                        } else {
                            Text(isEstimating ? "calculating…" : "—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingBadge: some View {
        if let reduction, reduction > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "−%.0f%%", reduction))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(reductionTint(for: reduction))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: reduction))
                Text("smaller")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if let reduction, reduction <= 0 {
            // Settings produce a larger file — warn the user.
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "+%.0f%%", -reduction))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                Text("larger")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .transition(.opacity)
        }
    }

    private func reductionTint(for percent: Double) -> Color {
        if percent >= 50 { .green }
        else if percent >= 25 { Color.green.opacity(0.85) }
        else { .secondary }
    }
}
