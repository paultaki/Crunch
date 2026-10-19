import CrunchCore
import Foundation
import Testing

@Suite("ImageFile.loadBatch")
struct ImageFileLoadBatchTests {
    /// The batch is loaded concurrently, so results come back from the task
    /// group in completion order, not input order. Widths descend across the
    /// batch so the first URL is the slowest to decode: an implementation
    /// that appended results as they arrived would reliably put the small
    /// images first and fail this, which is what makes the assertion worth
    /// having.
    @Test("returns files in the order they were given, not completion order")
    func preservesInputOrder() async throws {
        let widths = Array(stride(from: 600, through: 60, by: -45))
        var urls: [URL] = []
        for width in widths {
            urls.append(try TestImageFactory.makeSolidPNG(width: width, height: width / 2))
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let loaded = await ImageFile.loadBatch(from: urls)

        #expect(loaded.count == widths.count)
        #expect(loaded.map(\.pixelWidth) == widths)
        #expect(loaded.map(\.url) == urls)
    }

    /// `load` returns nil for anything it can't read, and `loadBatch`
    /// inherits that: the unreadable entries vanish and the survivors keep
    /// their relative order rather than shifting into the holes.
    @Test("drops entries that can't be loaded and keeps the survivors in order")
    func dropsFailuresWithoutDisturbingOrder() async throws {
        let first = try TestImageFactory.makeSolidPNG(width: 400, height: 200)
        let second = try TestImageFactory.makeSolidPNG(width: 80, height: 40)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        // An unsupported extension (rejected on format) and a path that
        // isn't there at all (rejected on read) — the two ways `load` bails.
        let unsupported = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-test-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: unsupported)
        defer { try? FileManager.default.removeItem(at: unsupported) }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-test-\(UUID().uuidString).png")

        let loaded = await ImageFile.loadBatch(
            from: [unsupported, first, missing, second]
        )

        #expect(loaded.map(\.url) == [first, second])
    }

    @Test("returns an empty array for an empty batch")
    func handlesEmptyBatch() async {
        let loaded = await ImageFile.loadBatch(from: [])
        #expect(loaded.isEmpty)
    }
}
