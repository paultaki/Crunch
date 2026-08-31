import CoreGraphics
import Foundation
import ImageIO

public enum AppState: Equatable, Sendable {
    case empty
    case loaded
    case compressing(completed: Int, total: Int)
    case results
}

public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case webp
    case avif

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .avif: "AVIF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        case .avif: "avif"
        }
    }

    public static func from(extension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "webp": .webp
        case "avif": .avif
        default: nil
        }
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case same = "Same"
    case png = "PNG"
    case webp = "WebP"
    case jpeg = "JPEG"
    case avif = "AVIF"

    /// AVIF's UTI — not exposed as a static `UTType.avif` member on this
    /// SDK, so referenced by its raw identifier. Shared by the encoder
    /// (`AVIFCompressor`) and the availability check below so both track
    /// the same string.
    static let avifTypeIdentifier = "public.avif"

    /// Whether this Mac's ImageIO can encode AVIF. AVIF encode support
    /// varies by OS/hardware even within the macOS 15 deployment target, so
    /// this is checked at runtime — via `CGImageDestinationCopyTypeIdentifiers`,
    /// which reflects installed codecs — rather than assumed. Computed once
    /// since that doesn't change mid-run.
    public static let avifEncodingSupported: Bool = {
        guard let types = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return types.contains(avifTypeIdentifier)
    }()

    /// `allCases` filtered to formats this Mac can actually produce. UI
    /// pickers should use this instead of `allCases` so AVIF quietly
    /// disappears on a system where ImageIO can't encode it.
    public static var availableCases: [OutputFormat] {
        allCases.filter { $0 != .avif || avifEncodingSupported }
    }

    public func resolve(for original: ImageFormat) -> ImageFormat {
        switch self {
        case .same: original
        case .png: .png
        case .webp: .webp
        case .jpeg: .jpeg
        case .avif: .avif
        }
    }
}

public enum ColorTier: Sendable {
    case green    // >50% reduction
    case yellow   // 25-50%
    case gray     // <25%
    case skipped  // already optimized — original kept, nothing replaced
    case grew     // format conversion that grew the file
    case red      // failed

    public static func from(reduction: Double) -> ColorTier {
        if reduction > 50 { .green }
        else if reduction > 25 { .yellow }
        else if reduction < 0 { .grew }
        else { .gray }
    }
}
