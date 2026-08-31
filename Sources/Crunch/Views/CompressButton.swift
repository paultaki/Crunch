import SwiftUI

struct CompressButton: View {
    let enabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.body.weight(.semibold))
                Text("Compress")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Compress all queued images (⌘↩)")
        .scaleEffect(isHovering && enabled ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 20)
    }
}
