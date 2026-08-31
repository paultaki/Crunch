import Foundation

enum AppState: Equatable {
    case empty
    case loaded
    case compressing(completed: Int, total: Int)
    case results
}

enum ImageFormat: String, CaseIterable {
    case png
    case jpeg
    case webp

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        }
    }

    static func from(extension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "webp": .webp
        default: nil
        }
    }
}

enum OutputFormat: String, CaseIterable {
    case same = "Same"
    case png = "PNG"
    case webp = "WebP"
    case jpeg = "JPEG"

    func resolve(for original: ImageFormat) -> ImageFormat {
        switch self {
        case .same: original
        case .png: .png
        case .webp: .webp
        case .jpeg: .jpeg
        }
    }
}

enum ColorTier {
    case green    // >50% reduction
    case yellow   // 25-50%
    case gray     // <25%
    case skipped  // already optimized — original kept, nothing replaced
    case grew     // format conversion that grew the file
    case red      // failed

    static func from(reduction: Double) -> ColorTier {
        if reduction > 50 { .green }
        else if reduction > 25 { .yellow }
        else if reduction < 0 { .grew }
        else { .gray }
    }
}
