import AppKit
import CrunchCore
import SwiftUI

struct ResultsView: View {
    let results: [CompressionResult]

    /// The folder holding this batch's output files, for "Show in Finder".
    /// All results land in the same source directory, so the first
    /// successful/skipped result's parent dir speaks for the batch.
    private var containingFolder: URL? {
        results.compactMap(\.outputURL).first?.deletingLastPathComponent()
    }

    /// Re-checked on every render (cheap `FileManager` stat) rather than
    /// cached, so the button only shows when a backup genuinely exists on
    /// disk right now — not a stale guess from when results were produced.
    /// Derived from `containingFolder` (not an independent scan of every
    /// result's parent dir) so the two footer buttons always agree on which
    /// folder they're pointing at, even for a batch spanning multiple
    /// source directories.
    private var backupFolder: URL? {
        guard let containingFolder else { return nil }
        let candidate = containingFolder.appendingPathComponent(BackupService.backupFolderName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { result in
                        ResultRowView(result: result)
                        if result.id != results.last?.id {
                            Divider()
                                .padding(.leading, 40)
                                .opacity(0.5)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var footer: some View {
        if containingFolder != nil || backupFolder != nil {
            Divider().opacity(0.5)
            HStack(spacing: 4) {
                if let containingFolder {
                    footerButton("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.open(containingFolder)
                    }
                }
                if let backupFolder {
                    footerButton("Open Backup Folder", systemImage: "clock.arrow.circlepath") {
                        NSWorkspace.shared.open(backupFolder)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}
