import XCTest
@testable import Hoatzin

/// SwiftUI's developer tools have a LibraryItem too.
private typealias LibraryItem = Hoatzin.LibraryItem

final class LibraryMergeTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    private func ssh(_ n: Int, _ name: String, host: String = "host") -> LibraryItem {
        var item = LibraryItem.sshConnection(name, config: SSHConfig(host: host))
        item.id = id(n)
        return item
    }

    private func folder(_ n: Int, _ name: String, _ children: [LibraryItem] = []) -> LibraryItem {
        var item = LibraryItem.folder(name)
        item.id = id(n)
        item.children = children
        return item
    }

    /// The tree as "name(child child)" for short assertions.
    private func shape(_ items: [LibraryItem]) -> String {
        items.map { $0.kind == .folder ? "\($0.name)(\(shape($0.children)))" : $0.name }.joined(separator: " ")
    }

    private func merge(_ base: [LibraryItem], _ local: [LibraryItem], _ remote: [LibraryItem]) -> String {
        shape(LibraryMerge.merge(base: base, local: local, remote: remote))
    }

    func testUnchangedSidesGiveTheBase() {
        let base = [folder(1, "F", [ssh(2, "a")]), ssh(3, "b")]
        XCTAssertEqual(LibraryMerge.merge(base: base, local: base, remote: base), base)
    }

    func testOneSidedChangesWin() {
        let base = [folder(1, "F", [ssh(2, "a")]), ssh(3, "b")]
        let changed = [folder(1, "F", [ssh(2, "a2"), ssh(4, "new")])]
        XCTAssertEqual(LibraryMerge.merge(base: base, local: changed, remote: base), changed)
        XCTAssertEqual(LibraryMerge.merge(base: base, local: base, remote: changed), changed)
    }

    func testAdditionsOnBothSidesAreKept() {
        let base = [ssh(1, "a"), ssh(2, "b")]
        let local = [ssh(1, "a"), ssh(3, "local"), ssh(2, "b")]
        let remote = [ssh(1, "a"), ssh(2, "b"), ssh(4, "remote")]
        XCTAssertEqual(merge(base, local, remote), "a local b remote")
    }

    func testEditsOfDifferentEntriesAreBothKept() {
        let base = [ssh(1, "a"), ssh(2, "b")]
        let merged = LibraryMerge.merge(base: base, local: [ssh(1, "a", host: "10.0.0.1"), ssh(2, "b")],
                                        remote: [ssh(1, "a"), ssh(2, "b2")])
        XCTAssertEqual(merged.map(\.name), ["a", "b2"])
        XCTAssertEqual(merged[0].ssh?.host, "10.0.0.1")
    }

    func testRemoteWinsWhenBothEditTheSameEntry() {
        let base = [ssh(1, "a")]
        XCTAssertEqual(merge(base, [ssh(1, "local")], [ssh(1, "remote")]), "remote")
    }

    func testDeletionOfAnUnchangedEntry() {
        let base = [ssh(1, "a"), ssh(2, "b")]
        XCTAssertEqual(merge(base, [ssh(2, "b")], base), "b")
        XCTAssertEqual(merge(base, base, [ssh(1, "a")]), "a")
    }

    func testAnEditBeatsADeletion() {
        let base = [ssh(1, "a"), ssh(2, "b")]
        XCTAssertEqual(merge(base, [ssh(2, "b")], [ssh(1, "a edited"), ssh(2, "b")]), "a edited b")
        XCTAssertEqual(merge(base, [ssh(1, "a"), ssh(2, "b edited")], [ssh(1, "a")]), "a b edited")
    }

    func testADeletedFolderComesBackForANewEntryInIt() {
        let base = [folder(1, "F", [ssh(2, "a")]), ssh(3, "b")]
        let local = [folder(1, "F", [ssh(2, "a"), ssh(4, "new")]), ssh(3, "b")]
        let remote = [ssh(3, "b")]
        // "a" stays deleted, "new" keeps its folder.
        XCTAssertEqual(merge(base, local, remote), "F(new) b")
    }

    func testMoveAndRenameOfTheSameEntryCombine() {
        let base = [folder(1, "F"), ssh(2, "a")]
        let local = [folder(1, "F", [ssh(2, "a")])]
        let remote = [folder(1, "F"), ssh(2, "renamed")]
        XCTAssertEqual(merge(base, local, remote), "F(renamed)")
    }

    func testFoldersMovedIntoEachOtherDoNotFormALoop() {
        let base = [folder(1, "A"), folder(2, "B"), ssh(3, "c")]
        let local = [folder(2, "B", [folder(1, "A")]), ssh(3, "c")]
        let remote = [folder(1, "A", [folder(2, "B")]), ssh(3, "c")]
        let merged = LibraryMerge.merge(base: base, local: local, remote: remote)
        var names: [String] = []
        func walk(_ items: [LibraryItem]) { for item in items { names.append(item.name); walk(item.children) } }
        walk(merged)
        XCTAssertEqual(names.sorted(), ["A", "B", "c"])
    }

    func testALocalReorderKeepsRemoteAdditions() {
        let base = [ssh(1, "a"), ssh(2, "b"), ssh(3, "c")]
        let local = [ssh(3, "c"), ssh(1, "a"), ssh(2, "b")]
        let remote = [ssh(1, "a"), ssh(4, "d"), ssh(2, "b"), ssh(3, "c")]
        XCTAssertEqual(merge(base, local, remote), "c a d b")
    }

    func testFirstMergeWithoutABaseIsAUnion() {
        let local = [ssh(1, "a"), ssh(2, "b local")]
        let remote = [ssh(2, "b remote"), ssh(3, "c")]
        XCTAssertEqual(merge([], local, remote), "a b remote c")
    }
}

final class LibrarySyncPlanTests: XCTestCase {
    private let a = LibraryItem.sshConnection("a", config: SSHConfig(host: "a"))
    private let b = LibraryItem.sshConnection("b", config: SSHConfig(host: "b"))

    func testFirstSyncUploadsWhenICloudIsEmpty() {
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [a], remote: nil), .init(upload: [a]))
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [a], remote: []), .init(upload: [a]))
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [], remote: nil), .init())
    }

    func testFirstSyncDownloadsIntoAnEmptyLibrary() {
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [], remote: [a]), .init(download: [a]))
    }

    func testFirstSyncAsksWhenBothDiffer() {
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [a], remote: [b]), .init(needsChoice: true))
        XCTAssertEqual(LibrarySync.plan(base: nil, local: [a], remote: [a]), .init())
    }

    func testLaterSyncsMerge() {
        XCTAssertEqual(LibrarySync.plan(base: [a], local: [a, b], remote: [a]), .init(upload: [a, b]))
        XCTAssertEqual(LibrarySync.plan(base: [a], local: [a], remote: [a, b]), .init(download: [a, b]))
        XCTAssertEqual(LibrarySync.plan(base: [a], local: [a], remote: [a]), .init())
        // The record was removed from iCloud by another Mac's reset: this Mac's library goes up again.
        XCTAssertEqual(LibrarySync.plan(base: [a], local: [a], remote: nil), .init(upload: [a]))
    }

    func testPayloadRoundTripAndNewerFormats() throws {
        let data = try LibrarySync.encodePayload([a, b])
        XCTAssertEqual(try LibrarySync.decodePayload(data), [a, b])
        let newer = Data(#"{"version":99,"items":[]}"#.utf8)
        let packed = try (newer as NSData).compressed(using: .lzfse) as Data
        XCTAssertThrowsError(try LibrarySync.decodePayload(packed))
    }

    func testInactiveWithoutTheEntitlement() {
        // The test runner has no iCloud entitlement, so CloudKit must never be touched.
        XCTAssertFalse(LibrarySync.hasCloudKitEntitlement)
    }
}
