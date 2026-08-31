import CrunchCore
import Testing

@Suite("OutputFormat.resolve")
struct OutputFormatResolveTests {
    @Test("auto (.same) keeps the original format", arguments: ImageFormat.allCases)
    func autoKeepsOriginalFormat(original: ImageFormat) {
        #expect(OutputFormat.same.resolve(for: original) == original)
    }

    @Test("explicit output formats always convert, regardless of source format")
    func explicitFormatsAlwaysConvert() {
        let explicitOutputs: [(OutputFormat, ImageFormat)] = [
            (.png, .png), (.jpeg, .jpeg), (.webp, .webp), (.avif, .avif)
        ]

        for (output, expected) in explicitOutputs {
            for original in ImageFormat.allCases {
                #expect(output.resolve(for: original) == expected)
            }
        }
    }

    @Test("availableCases always includes the non-AVIF formats")
    func availableCasesAlwaysIncludesNonAVIFFormats() {
        let available = Set(OutputFormat.availableCases)
        #expect(available.isSuperset(of: [.same, .png, .webp, .jpeg]))
    }

    @Test("availableCases includes AVIF exactly when this Mac's ImageIO can encode it")
    func availableCasesMatchesAVIFEncodingSupport() {
        let available = Set(OutputFormat.availableCases)
        #expect(available.contains(.avif) == OutputFormat.avifEncodingSupported)
    }
}
