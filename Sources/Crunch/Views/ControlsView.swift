import CrunchCore
import SwiftUI

struct ControlsView: View {
    @Binding var settings: CompressionSettings

    var body: some View {
        VStack(spacing: 18) {
            controlBlock(title: "Output Format") {
                Picker("Format", selection: $settings.outputFormat) {
                    ForEach(OutputFormat.availableCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            controlBlock(title: "Resolution") {
                Picker("Resolution", selection: $settings.resolutionPercent) {
                    Text("100%").tag(100)
                    Text("75%").tag(75)
                    Text("50%").tag(50)
                    Text("25%").tag(25)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            controlBlock(
                title: "Quality",
                trailing: {
                    Text("\(settings.quality)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )
                }
            ) {
                Slider(
                    value: Binding(
                        get: { Double(settings.quality) },
                        set: { settings.quality = Int($0) }
                    ),
                    in: 1...100,
                    step: 1
                )
            }

            // Phrased as what it removes rather than as "preserve metadata",
            // so an untouched control is the safe one: off means nothing is
            // thrown away. The footnote names GPS specifically because that
            // is the reason anyone reaches for this, and says what is kept so
            // nobody expects their photos to come out sideways.
            controlBlock(title: "Metadata") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Strip metadata", isOn: $settings.stripMetadata)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(
                        settings.stripMetadata
                            ? "Removes capture date, camera and GPS. Orientation is kept."
                            : "Keeps capture date, camera, GPS and orientation."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func controlBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    @ViewBuilder
    private func controlBlock<Content: View, Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                trailing()
            }
            content()
        }
    }
}
