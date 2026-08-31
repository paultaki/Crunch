import SwiftUI

// Alert content is handled inline in ContentView via .alert modifier.
// This file provides the helper text for missing tool messages.

enum MissingToolsMessage {
    static let pngquant = "pngquant is not installed. Run in Terminal:\n\nbrew install pngquant"
    static let cwebp = "cwebp is not installed. Run in Terminal:\n\nbrew install webp"
    static let both = "pngquant and cwebp are not installed. Run in Terminal:\n\nbrew install pngquant webp"

    /// One-line notice for inline UI (the estimate preview) — same tools,
    /// terser copy than the full alert text above.
    static func compactInstallHint(for format: ImageFormat) -> String? {
        switch format {
        case .png: "Install pngquant for PNG estimates"
        case .webp: "Install cwebp for WebP estimates"
        case .jpeg: nil // JPEG compression uses ImageIO, no external tool
        }
    }
}
