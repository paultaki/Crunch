import SwiftUI
import UniformTypeIdentifiers

/// Drop zone that accepts image files and image-containing folders.
///
/// Providers are resolved concurrently into URLs, then sorted for
/// deterministic ordering before being handed to the view model in a single
/// batch — this keeps file lists stable even when the OS delivers providers
/// in arbitrary order after a multi-file drop.
struct DropZoneView: View {
    let compact: Bool
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    private static let validExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    var body: some View {
        Group {
            if compact { compactDropZone } else { fullDropZone }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Presentation

    private var fullDropZone: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(isTargeted ? 0.18 : 0.08))
                    .frame(width: 96, height: 96)
                    .scaleEffect(isTargeted ? 1.08 : 1.0)

                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce.up, value: isTargeted)
            }

            VStack(spacing: 4) {
                Text("Drop images to compress")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("PNG, JPEG, WebP — or a folder of them")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [9, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isTargeted
                              ? Color.accentColor.opacity(0.06)
                              : Color.primary.opacity(0.015))
                )
        }
        .padding(28)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isTargeted)
    }

    private var compactDropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(isTargeted ? "Release to add" : "Drop more images")
                .font(.subheadline)
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.18), value: isTargeted)
    }

    // MARK: - Drop handling

    /// Resolves providers into URLs, expands folders, filters by extension,
    /// and dispatches a single sorted batch on the main actor.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        Task {
            var collected: [URL] = []
            for provider in providers {
                if let url = await Self.loadURL(from: provider) {
                    collected.append(contentsOf: Self.expand(url))
                }
            }
            let sorted = collected
                .filter { Self.validExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if !sorted.isEmpty {
                await MainActor.run { onDrop(sorted) }
            }
        }
        return true
    }

    /// Bridges `NSItemProvider.loadItem` into async/await.
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { data, _ in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Returns `[url]` for files or the enumerated contents for directories
    /// (non-recursive — one level deep is typical user intent).
    private static func expand(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue { return [url] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
    }
}
