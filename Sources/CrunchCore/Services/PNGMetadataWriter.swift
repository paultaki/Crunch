import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rewrites the metadata of a finished PNG in place, by chunk surgery rather
/// than by re-encoding.
///
/// This exists because `pngquant` gives us no choice. On macOS it strips
/// metadata **by default** — its own `--help` says
/// `--strip  remove optional metadata (default on Mac)` — and there is no
/// inverse flag to turn that off. Measured on pngquant 3.0.3: it drops the
/// `eXIf` chunk outright and happens to keep the Adobe XMP `iTXt` chunk,
/// which is why some tags appeared to survive while orientation did not.
/// Relying on that XMP accident would leave orientation — the tag with the
/// visible consequence — at the mercy of whether ImageIO chose to duplicate
/// it into XMP.
///
/// Re-encoding pngquant's output through ImageIO is not an option: it would
/// throw away the palette quantization that is the entire point of running
/// pngquant, ballooning a 26KB file back to 73KB.
///
/// So instead we edit the container: drop whatever metadata chunks are there
/// and splice in a freshly-minted `eXIf`, leaving every `IDAT` byte untouched.
/// In practice the result is *smaller* than pngquant's own output, because
/// the compact EXIF blob replaces the verbose XMP one.
enum PNGMetadataWriter {
    /// The 8-byte PNG signature every file must start with.
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The `iTXt` keyword Adobe XMP packets use. Matched exactly so that
    /// stripping metadata removes the XMP pngquant preserved, while leaving
    /// any other text chunk alone.
    private static let xmpKeyword = "XML:com.adobe.xmp"

    /// Replaces the PNG's metadata with `metadata`, or removes it entirely
    /// when `metadata` is nil.
    ///
    /// Passing nil is what makes the "Strip metadata" setting honest for PNG:
    /// pngquant's default already loses the `eXIf` chunk, but it leaves the
    /// XMP packet — which still carries the capture date and GPS — in place.
    static func apply(_ metadata: ImageMetadata?, to url: URL) throws {
        let original = [UInt8](try Data(contentsOf: url))
        guard original.count > signature.count,
              Array(original.prefix(signature.count)) == signature
        else {
            throw CompressionError.cannotWriteImage(url.lastPathComponent)
        }

        // Minted at the output's own dimensions, not the original's: ImageIO
        // stamps the EXIF pixel-dimension tags from the image it writes, so a
        // placeholder of the wrong size produces a payload claiming the wrong
        // size. Read them out of this file's IHDR rather than trusting the
        // caller to have tracked any resize.
        var exif: Data?
        if let metadata {
            // A PNG with no readable IHDR is not a PNG we should be
            // rewriting, so this throws rather than quietly carrying on —
            // we are about to overwrite the file.
            guard let size = dimensions(of: original) else {
                throw CompressionError.cannotWriteImage(url.lastPathComponent)
            }
            // A nil payload here does NOT throw, deliberately. It means
            // ImageIO emitted no EXIF for this metadata — which happens when
            // the source carried only something EXIF cannot express, IPTC
            // being the realistic case. Failing the whole compression over
            // metadata we were never able to represent would be a worse
            // outcome for the user than handing back the compressed file
            // without it, which is no worse than before any of this existed.
            exif = exifPayload(for: metadata, width: size.width, height: size.height)
        }

        var rewritten = Array(original.prefix(signature.count))
        var index = signature.count

        while index + 8 <= original.count {
            let length = Int(bigEndian: original, at: index)
            let typeRange = (index + 4)..<(index + 8)
            let type = String(decoding: original[typeRange], as: UTF8.self)
            let end = index + 12 + length
            guard length >= 0, end <= original.count else {
                throw CompressionError.cannotWriteImage(url.lastPathComponent)
            }

            let payload = Array(original[(index + 8)..<(index + 8 + length)])
            if !isMetadataChunk(type: type, payload: payload) {
                rewritten.append(contentsOf: original[index..<end])
            }

            // Directly after IHDR, which is always the first chunk. `eXIf` is
            // legal anywhere before IEND; before IDAT is where decoders
            // expect to find it.
            if type == "IHDR", let exif {
                rewritten.append(contentsOf: chunk(type: "eXIf", payload: [UInt8](exif)))
            }

            index = end
        }

        try Data(rewritten).write(to: url, options: .atomic)
    }

    // MARK: - Chunk plumbing

    private static func isMetadataChunk(type: String, payload: [UInt8]) -> Bool {
        if type == "eXIf" { return true }
        // An iTXt payload opens with a NUL-terminated keyword.
        if type == "iTXt", let nul = payload.firstIndex(of: 0) {
            return String(decoding: payload[0..<nul], as: UTF8.self) == xmpKeyword
        }
        return false
    }

    /// Width and height out of the IHDR chunk, which the PNG spec requires to
    /// be the first chunk after the signature.
    private static func dimensions(of png: [UInt8]) -> (width: Int, height: Int)? {
        let ihdr = signature.count + 8
        guard png.count >= ihdr + 8,
              String(decoding: png[(signature.count + 4)..<ihdr], as: UTF8.self) == "IHDR"
        else { return nil }
        return (Int(bigEndian: png, at: ihdr), Int(bigEndian: png, at: ihdr + 4))
    }

    /// Mints a raw EXIF (TIFF-structured) blob for `metadata` by asking
    /// ImageIO to write a throwaway PNG in memory and lifting its `eXIf`
    /// chunk back out.
    ///
    /// Round-tripping through ImageIO rather than hand-rolling a TIFF writer
    /// keeps us honest about tag encoding, and means this works no matter what
    /// format the metadata originally came from — a JPEG's APP1 segment and a
    /// PNG's `eXIf` chunk both arrive here as the same property dictionary.
    ///
    /// The placeholder is 1 bit per pixel and entirely zero, so even at
    /// 4000x3000 it is an 8KB encode that measures at 2ms — the dimensions
    /// matter (see `apply`) but the cost of matching them does not.
    private static func exifPayload(
        for metadata: ImageMetadata,
        width: Int,
        height: Int
    ) -> Data? {
        let bytesPerRow = (width + 7) / 8
        let blank = Data(count: bytesPerRow * height)
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: blank as CFData),
              let placeholder = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 1,
                  bitsPerPixel: 1,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, placeholder, metadata.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return firstChunkPayload(type: "eXIf", in: [UInt8](buffer as Data))
    }

    private static func firstChunkPayload(type: String, in png: [UInt8]) -> Data? {
        var index = signature.count
        while index + 8 <= png.count {
            let length = Int(bigEndian: png, at: index)
            let end = index + 12 + length
            guard length >= 0, end <= png.count else { return nil }
            if String(decoding: png[(index + 4)..<(index + 8)], as: UTF8.self) == type {
                return Data(png[(index + 8)..<(index + 8 + length)])
            }
            index = end
        }
        return nil
    }

    /// Assembles a complete PNG chunk: big-endian length, type, payload, CRC.
    private static func chunk(type: String, payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        return UInt32(payload.count).bigEndianBytes + body + crc32(body).bigEndianBytes
    }

    /// PNG's CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) over the
    /// chunk type and payload. Hand-rolled because Foundation exposes no
    /// CRC-32 and pulling in zlib for sixteen lines is not worth a dependency.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var remainder = UInt32(index)
        for _ in 0..<8 {
            remainder = (remainder & 1) != 0
                ? 0xEDB8_8320 ^ (remainder >> 1)
                : remainder >> 1
        }
        return remainder
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var remainder: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            remainder = crcTable[Int((remainder ^ UInt32(byte)) & 0xFF)] ^ (remainder >> 8)
        }
        return remainder ^ 0xFFFF_FFFF
    }
}

private extension Int {
    /// Reads the big-endian 32-bit integer PNG uses for every length and
    /// dimension field.
    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
    }
}
