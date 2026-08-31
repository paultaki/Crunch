import Foundation

// Alert content is handled inline in ContentView via .alert modifier.
// This file provides the helper text for missing tool messages.

public enum MissingToolsMessage {
    public static let pngquant = "pngquant is not installed. Run in Terminal:\n\nbrew install pngquant"
    public static let cwebp = "cwebp is not installed. Run in Terminal:\n\nbrew install webp"
    public static let both = "pngquant and cwebp are not installed. Run in Terminal:\n\nbrew install pngquant webp"

    /// Shared with `CompressionError.avifNotSupported` so the compress-run
    /// error and the estimate-preview inline hint say the same thing.
    /// Unlike pngquant/cwebp, there's no install fix — the deployed OS/
    /// hardware just doesn't have an AVIF encoder.
    public static let avifUnsupported = "AVIF encoding isn't supported on this Mac"

    /// One-line notice for inline UI (the estimate preview) — same tools,
    /// terser copy than the full alert text above.
    public static func compactInstallHint(for format: ImageFormat) -> String? {
        switch format {
        case .png: "Install pngquant for PNG estimates"
        case .webp: "Install cwebp for WebP estimates"
        case .jpeg: nil // JPEG compression uses ImageIO, no external tool
        case .avif: nil // AVIF compression uses ImageIO — see compactUnsupportedHint
        }
    }

    /// One-line notice for a format this Mac's ImageIO can't encode at all
    /// (no install fixes it, unlike `compactInstallHint`'s subprocess
    /// tools). Currently only AVIF can hit this.
    public static func compactUnsupportedHint(for format: ImageFormat) -> String? {
        switch format {
        case .avif: avifUnsupported
        case .png, .webp, .jpeg: nil
        }
    }
}
