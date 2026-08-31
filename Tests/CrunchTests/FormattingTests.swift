import CrunchCore
import Testing

@Suite("Formatting")
struct FormattingTests {
    @Test("formats kilobyte-scale sizes with a KB unit")
    func formatsKilobytes() {
        let value: Int64 = 2_400
        #expect(value.formattedBytes.contains("KB"))
    }

    @Test("formats megabyte-scale sizes with an MB unit")
    func formatsMegabytes() {
        let value: Int64 = 2_400_000
        #expect(value.formattedBytes.contains("MB"))
    }

    @Test("formats gigabyte-scale sizes with a GB unit")
    func formatsGigabytes() {
        let value: Int64 = 2_400_000_000
        #expect(value.formattedBytes.contains("GB"))
    }
}
