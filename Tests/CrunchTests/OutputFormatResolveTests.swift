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
            (.png, .png), (.jpeg, .jpeg), (.webp, .webp)
        ]

        for (output, expected) in explicitOutputs {
            for original in ImageFormat.allCases {
                #expect(output.resolve(for: original) == expected)
            }
        }
    }
}
