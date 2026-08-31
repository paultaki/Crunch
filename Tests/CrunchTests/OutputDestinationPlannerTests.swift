import CrunchCore
import Foundation
import Testing

/// A `final class` (not a struct) so each test gets a fresh temp directory in
/// `init` and it's reliably cleaned up in `deinit`.
final class OutputDestinationPlannerTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crunch-destination-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test("same-format files keep their own URL so the atomic replace stays correct")
    func inPlaceKeepsSourceURL() throws {
        let source = try makeFile("photo.png")

        let plan = OutputDestinationPlanner.plan([
            .init(source: source, sourceFormat: .png, outputFormat: .png)
        ])

        #expect(plan == [source])
    }

    @Test("a conversion takes the plain new-extension path when nothing holds it")
    func conversionUsesPlainPathWhenFree() throws {
        let source = try makeFile("photo.png")

        let plan = OutputDestinationPlanner.plan([
            .init(source: source, sourceFormat: .png, outputFormat: .webp)
        ])

        #expect(plan == [tempDir.appendingPathComponent("photo.webp")])
    }

    @Test("a conversion never overwrites an existing file it didn't back up")
    func conversionUniquifiesAgainstExistingFile() throws {
        let source = try makeFile("photo.png")
        // A bystander the user never queued: it must survive untouched.
        let bystander = try makeFile("photo.jpg")

        let plan = OutputDestinationPlanner.plan([
            .init(source: source, sourceFormat: .png, outputFormat: .jpeg)
        ])

        #expect(plan == [tempDir.appendingPathComponent("photo-1.jpg")])
        #expect(FileManager.default.fileExists(atPath: bystander.path))
    }

    @Test("two batch files converging on one name get distinct destinations")
    func withinBatchCollisionsGetDistinctDestinations() throws {
        let png = try makeFile("photo.png")
        let jpg = try makeFile("photo.jpg")

        let plan = OutputDestinationPlanner.plan([
            .init(source: png, sourceFormat: .png, outputFormat: .webp),
            .init(source: jpg, sourceFormat: .jpeg, outputFormat: .webp)
        ])

        #expect(plan.count == 2)
        #expect(plan[0] != plan[1])
        #expect(plan[0] == tempDir.appendingPathComponent("photo.webp"))
        #expect(plan[1] == tempDir.appendingPathComponent("photo-1.webp"))
    }

    @Test("uniquifying skips past every taken name rather than stopping at -1")
    func uniquifyingSkipsRunsOfTakenNames() throws {
        let source = try makeFile("photo.png")
        _ = try makeFile("photo.webp")
        _ = try makeFile("photo-1.webp")

        let plan = OutputDestinationPlanner.plan([
            .init(source: source, sourceFormat: .png, outputFormat: .webp)
        ])

        #expect(plan == [tempDir.appendingPathComponent("photo-2.webp")])
    }

    @Test("an in-place destination isn't stolen by a conversion earlier in the batch")
    func conversionDoesNotStealAnInPlaceDestination() throws {
        let png = try makeFile("photo.png")
        let webp = try makeFile("photo.webp")

        let plan = OutputDestinationPlanner.plan([
            .init(source: png, sourceFormat: .png, outputFormat: .webp),
            .init(source: webp, sourceFormat: .webp, outputFormat: .webp)
        ])

        #expect(plan[0] == tempDir.appendingPathComponent("photo-1.webp"))
        #expect(plan[1] == webp)
    }

    @Test("availableURL leaves a free path alone")
    func availableURLPassesThroughFreePath() {
        let candidate = tempDir.appendingPathComponent("nothing-here.webp")
        #expect(OutputDestinationPlanner.availableURL(startingAt: candidate) == candidate)
    }

    @Test("availableURL keeps extensionless names extensionless")
    func availableURLHandlesEmptyExtension() throws {
        _ = try makeFile("photo")

        let next = OutputDestinationPlanner.availableURL(
            startingAt: tempDir.appendingPathComponent("photo")
        )

        #expect(next.lastPathComponent == "photo-1")
    }
}
