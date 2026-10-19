import CoreGraphics
import Foundation

/// Applies an EXIF orientation to the pixels themselves, returning an image
/// that is upright with no tag needed.
///
/// Only used for AVIF, and only because ImageIO leaves no alternative: its
/// AVIF encoder **discards orientation unconditionally**, writing 1 even when
/// handed an explicit `kCGImageDestinationOrientation`. Measured 2026-10-19;
/// HEIC, the same container family through the same API, preserves it, so
/// this is specific to the AVIF encoder rather than a mistake in how we call
/// it. Without baking, a phone photo converted to AVIF comes out rotated 90°
/// — the exact symptom the metadata work exists to fix.
///
/// Every other format carries the tag, which is strictly better: it is
/// lossless, and a tag costs nothing while re-drawing the pixels costs a full
/// decode-and-redraw. So nothing else calls this.
enum OrientationBaker {
    /// Whether `orientation` describes anything other than "already upright".
    /// Callers skip the redraw entirely for the overwhelmingly common case.
    static func isUpright(_ orientation: Int) -> Bool { orientation == 1 }

    /// Returns `image` with `orientation` applied, or `image` unchanged when
    /// there is nothing to do.
    ///
    /// The eight EXIF orientations are four rotations and their mirrored
    /// counterparts. The transforms below are built in `CGContext`'s
    /// bottom-left origin space and were each verified against ImageIO's own
    /// `kCGImageSourceCreateThumbnailWithTransform` output — see
    /// `OrientationBakerTests`, which re-runs that comparison for all eight
    /// rather than trusting the arithmetic to be obviously right. (It is not:
    /// two of the eight were wrong on the first attempt, in ways only a
    /// corner-marker fixture catches.)
    static func bake(_ image: CGImage, orientation: Int) -> CGImage? {
        guard !isUpright(orientation) else { return image }

        let width = image.width
        let height = image.height
        // 5-8 are the transposed orientations: the displayed image has the
        // source's axes swapped, so the canvas does too.
        let swapsAxes = (5...8).contains(orientation)
        let outputWidth = swapsAxes ? height : width
        let outputHeight = swapsAxes ? width : height

        // Keep transparency if the source had any. AVIF supports alpha, and
        // redrawing into an opaque context would silently flatten it — the
        // same shape of quiet data loss this whole change exists to fix.
        // Straight alpha is normalized to premultiplied for the same reason
        // `ImageResizer` does it: `CGContext` rejects several straight-alpha
        // layouts outright, and reinterpreting straight alpha as
        // premultiplied corrupts colour at partially-transparent edges.
        let hasAlpha = image.alphaInfo != .none
            && image.alphaInfo != .noneSkipFirst
            && image.alphaInfo != .noneSkipLast
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        ) else { return nil }

        let canvasWidth = CGFloat(outputWidth)
        let canvasHeight = CGFloat(outputHeight)
        switch orientation {
        case 2: // mirrored horizontally
            context.translateBy(x: canvasWidth, y: 0)
            context.scaleBy(x: -1, y: 1)
        case 3: // rotated 180°
            context.translateBy(x: canvasWidth, y: canvasHeight)
            context.rotate(by: .pi)
        case 4: // mirrored vertically
            context.translateBy(x: 0, y: canvasHeight)
            context.scaleBy(x: 1, y: -1)
        case 5: // transposed (mirrored across the main diagonal)
            context.translateBy(x: canvasWidth, y: canvasHeight)
            context.rotate(by: -.pi / 2)
            context.scaleBy(x: 1, y: -1)
        case 6: // rotated 90° clockwise — by far the most common on phones
            context.translateBy(x: 0, y: canvasHeight)
            context.rotate(by: -.pi / 2)
        case 7: // transverse (mirrored across the anti-diagonal)
            context.rotate(by: .pi / 2)
            context.scaleBy(x: 1, y: -1)
        case 8: // rotated 90° counter-clockwise
            context.translateBy(x: canvasWidth, y: 0)
            context.rotate(by: .pi / 2)
        default:
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
