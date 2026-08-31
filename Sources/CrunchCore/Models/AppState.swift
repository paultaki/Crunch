import Foundation

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

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        }
    }

    public static func from(extension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "webp": .webp
        default: nil
        }
    }
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case same = "Same"
    case png = "PNG"
    case webp = "WebP"
    case jpeg = "JPEG"

    public func resolve(for original: ImageFormat) -> ImageFormat {
        switch self {
        case .same: original
        case .png: .png
        case .webp: .webp
        case .jpeg: .jpeg
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
