import XCTest
@testable import TopologyCore

/// The profile Trash's boundary check, against a real temporary folder with real links: the user's
/// profiles folder (`Profiles`), and somewhere else on disk (`Elsewhere`) a link must not reach.
final class ConfinedFileTests: XCTestCase {
    private var base: URL!
    private var profiles: URL!
    private var elsewhere: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory.appendingPathComponent("od-confined-\(UUID().uuidString)", isDirectory: true)
        profiles = base.appendingPathComponent("Profiles", isDirectory: true)
        elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try manager.createDirectory(at: profiles.appendingPathComponent("Vendor"), withIntermediateDirectories: true)
        try manager.createDirectory(at: elsewhere.appendingPathComponent("Vendor"), withIntermediateDirectories: true)
        try write(profiles.appendingPathComponent("Mine.icc"))
        try write(profiles.appendingPathComponent("Vendor/Calibrated.icc"))
        try write(elsewhere.appendingPathComponent("Vendor/Calibrated.icc"))
        try write(elsewhere.appendingPathComponent("Shared.icc"))
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: base)
    }

    private func write(_ url: URL) throws {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }

    private func refusal(_ url: URL) -> ConfinedFile.Refusal? {
        do { _ = try ConfinedFile.resolve(url, inside: profiles); return nil } catch {
            return error as? ConfinedFile.Refusal
        }
    }

    func testRegularFilesInsideTheFolderResolveToTheirRealLocation() throws {
        let root = ConfinedFile.boundary(of: profiles).path
        XCTAssertEqual(try ConfinedFile.resolve(profiles.appendingPathComponent("Mine.icc"), inside: profiles).path,
                       root + "/Mine.icc")
        XCTAssertEqual(try ConfinedFile.resolve(profiles.appendingPathComponent("Vendor/Calibrated.icc"),
                                                inside: profiles).path,
                       root + "/Vendor/Calibrated.icc")
    }

    /// The finding: the subfolder a listed profile sits in is swapped for a link after the list was
    /// read. The path's text still says "your profiles folder" — the old provenance check approved
    /// it — while `trashItem` would follow the link and remove the file elsewhere.
    func testASubfolderReplacedByALinkIsRefused() throws {
        let listed = profiles.appendingPathComponent("Vendor/Calibrated.icc")
        try manager.removeItem(at: profiles.appendingPathComponent("Vendor"))
        try manager.createSymbolicLink(at: profiles.appendingPathComponent("Vendor"),
                                       withDestinationURL: elsewhere.appendingPathComponent("Vendor"))
        XCTAssertEqual(ICCProfileCatalog.provenance(of: listed.path, factoryPaths: [], userFolder: profiles.path),
                       .user, "the textual check alone is fooled")
        XCTAssertEqual(refusal(listed), .linkedDirectory)
    }

    func testAProfileThatIsItselfALinkIsRefused() throws {
        let link = profiles.appendingPathComponent("Linked.icc")
        try manager.createSymbolicLink(at: link, withDestinationURL: elsewhere.appendingPathComponent("Shared.icc"))
        XCTAssertEqual(refusal(link), .notARegularFile)
    }

    func testPathsOutsideTheFolderAreRefused() {
        XCTAssertEqual(refusal(elsewhere.appendingPathComponent("Shared.icc")), .outsideFolder)
        XCTAssertEqual(refusal(URL(fileURLWithPath: profiles.path + "/../Elsewhere/Shared.icc")), .outsideFolder)
        XCTAssertEqual(refusal(profiles), .outsideFolder, "the folder itself is not a file in it")
        XCTAssertEqual(refusal(profiles.appendingPathComponent("Gone.icc")), .missing)
        XCTAssertEqual(refusal(profiles.appendingPathComponent("Vendor")), .notARegularFile)
    }

    /// The folder itself may be a link (it's what ColorSync reads); its real location is the boundary.
    func testALinkedFolderIsResolvedOnce() throws {
        let linkedFolder = base.appendingPathComponent("ProfilesLink")
        try manager.createSymbolicLink(at: linkedFolder, withDestinationURL: profiles)
        let resolved = try ConfinedFile.resolve(linkedFolder.appendingPathComponent("Mine.icc"), inside: linkedFolder)
        XCTAssertEqual(ConfinedFile.identity(of: resolved), ConfinedFile.identity(of: profiles.appendingPathComponent("Mine.icc")))
        // A path already in the real form is accepted too.
        XCTAssertNoThrow(try ConfinedFile.resolve(resolved, inside: linkedFolder))
    }

    func testIdentityFollowsTheFileNotThePath() throws {
        let mine = profiles.appendingPathComponent("Mine.icc")
        let link = elsewhere.appendingPathComponent("ToMine.icc")
        let hardLink = elsewhere.appendingPathComponent("HardMine.icc")
        try manager.createSymbolicLink(at: link, withDestinationURL: mine)
        try manager.linkItem(at: mine, to: hardLink)
        let identity = try XCTUnwrap(ConfinedFile.identity(of: mine))
        XCTAssertEqual(ConfinedFile.identity(of: link), identity)
        XCTAssertEqual(ConfinedFile.identity(of: hardLink), identity)
        XCTAssertNotEqual(ConfinedFile.identity(of: elsewhere.appendingPathComponent("Shared.icc")), identity)
        XCTAssertNil(ConfinedFile.identity(of: profiles.appendingPathComponent("Gone.icc")))

        // A different file put at the listed path has a different identity.
        try manager.removeItem(at: mine)
        try write(mine)
        XCTAssertNotEqual(ConfinedFile.identity(of: mine), identity)
    }

    func testDestinationForPuttingAFileBack() throws {
        let root = ConfinedFile.boundary(of: profiles).path
        XCTAssertEqual(try ConfinedFile.resolveDestination(profiles.appendingPathComponent("Back.icc"), inside: profiles).path,
                       root + "/Back.icc")
        XCTAssertEqual(try ConfinedFile.resolveDestination(profiles.appendingPathComponent("New/Sub/Back.icc"),
                                                           inside: profiles).path,
                       root + "/New/Sub/Back.icc", "missing folders are the caller's to create")
        try manager.createSymbolicLink(at: profiles.appendingPathComponent("Away"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ConfinedFile.resolveDestination(profiles.appendingPathComponent("Away/Back.icc"),
                                                                 inside: profiles)) {
            XCTAssertEqual($0 as? ConfinedFile.Refusal, .linkedDirectory)
        }
        XCTAssertThrowsError(try ConfinedFile.resolveDestination(profiles.appendingPathComponent("Mine.icc"),
                                                                 inside: profiles)) {
            XCTAssertEqual($0 as? ConfinedFile.Refusal, .notARegularFile, "never overwrites what took its place")
        }
        XCTAssertThrowsError(try ConfinedFile.resolveDestination(elsewhere.appendingPathComponent("Back.icc"),
                                                                 inside: profiles)) {
            XCTAssertEqual($0 as? ConfinedFile.Refusal, .outsideFolder)
        }
    }
}
