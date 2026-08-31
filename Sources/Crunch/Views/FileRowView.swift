import SwiftUI

struct FileRowView: View {
    let file: ImageFile
    let resolutionPercent: Int
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(decorative: file.thumbnail, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(file.originalSize.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text(file.format.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )

                    if resolutionPercent < 100 {
                        let dims = file.resizedDimensions(percent: resolutionPercent)
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.forward")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(dims.width)×\(dims.height)")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.orange)
                        .monospacedDigit()
                    }
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Remove from list")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 18)
        .background(
            Rectangle()
                .fill(isHovering ? Color.primary.opacity(0.045) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
