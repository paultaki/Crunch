import SwiftUI

// Alert content is handled inline in ContentView via .alert modifier.
// This file provides the helper text for missing tool messages.

enum MissingToolsMessage {
    static let pngquant = "pngquant is not installed. Run in Terminal:\n\nbrew install pngquant"
    static let cwebp = "cwebp is not installed. Run in Terminal:\n\nbrew install webp"
    static let both = "pngquant and cwebp are not installed. Run in Terminal:\n\nbrew install pngquant webp"
}
