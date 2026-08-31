import AppKit
import CrunchCore
import SwiftUI

/// Squoosh-style before/after preview, opened as a sheet from the Preview
/// button in `EstimatePreviewView`. Both images are decoded into `NSImage`
/// exactly once in `onAppear` — the drag gesture below only ever changes
/// `dividerFraction`, which resizes a mask, so dragging never re-decodes or
/// re-lays-out the images and stays smooth at any frame rate.
///
/// Fit-to-view only: no zoom/pan controls, matching the estimate preview's
/// scope (this is a quick gut-check, not an image viewer).
struct ComparePreviewView: View {
    let original: URL
    let compressed: URL

    @Environment(\.dismiss) private var dismiss
    @State private var originalImage: NSImage?
    @State private var compressedImage: NSImage?
    /// 0 = fully compressed showing, 1 = fully original showing. Starts
    /// centered.
    @State private var dividerFraction: CGFloat = 0.5
    @State private var originalBytes: Int64 = 0
    @State private var compressedBytes: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            imageArea
                .padding(20)
            labels
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear(perform: loadImages)
        .onExitCommand { dismiss() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Original / Compressed")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Image area

    @ViewBuilder
    private var imageArea: some View {
        if let originalImage, let compressedImage {
            GeometryReader { proxy in
                let size = fitSize(for: originalImage.size, in: proxy.size)

                ZStack {
                    Image(nsImage: originalImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)

                    Image(nsImage: compressedImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: size.width * (1 - dividerFraction))
                                .offset(x: size.width * dividerFraction)
                        }

                    dividerHandle(size: size)
                }
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: size.width))
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                dividerFraction = min(max(value.location.x / width, 0), 1)
            }
    }

    private func dividerHandle(size: CGSize) -> some View {
        let x = size.width * dividerFraction
        return ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: size.height)
            Circle()
                .fill(Color.white)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black.opacity(0.7))
                )
        }
        .shadow(color: .black.opacity(0.35), radius: 3)
        .position(x: x, y: size.height / 2)
        .allowsHitTesting(false)
    }

    /// Scales `imageSize` to fit entirely within `bounds` — up or down —
    /// preserving aspect ratio. "Fit-to-view only" per the task brief: no
    /// interactive zoom, so this is the one and only sizing pass.
    private func fitSize(for imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Labels

    private var labels: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Original")
                    .font(.caption.weight(.semibold))
                Text(originalBytes.formattedBytes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Compressed")
                    .font(.caption.weight(.semibold))
                Text(compressedBytes.formattedBytes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Loading

    /// Decodes both images and reads both file sizes exactly once, at sheet
    /// open. `NSImage(contentsOf:)` routes through ImageIO, which on macOS
    /// 15 decodes AVIF and WebP natively — no format-specific handling
    /// needed here.
    private func loadImages() {
        originalImage = NSImage(contentsOf: original)
        compressedImage = NSImage(contentsOf: compressed)
        originalBytes = Self.fileSize(of: original)
        compressedBytes = Self.fileSize(of: compressed)
    }

    private static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }
}
