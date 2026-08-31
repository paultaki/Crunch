import SwiftUI

struct FileListView: View {
    let files: [ImageFile]
    let resolutionPercent: Int
    let onRemove: (ImageFile) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    FileRowView(
                        file: file,
                        resolutionPercent: resolutionPercent,
                        onRemove: { onRemove(file) }
                    )
                    if file.id != files.last?.id {
                        Divider()
                            .padding(.leading, 72)
                            .opacity(0.5)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
