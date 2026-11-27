import XCTest
@testable import Hoatzin
@testable import HoatzinCore

/// Favourites live in the library (Favorites.swift), so iCloud sync carries them to the iOS app.
@MainActor
final class FavoritesTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
        urls = []
    }

    private func newStore() -> LibraryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-favorites-\(UUID()).json")
        urls.append(url)
        return LibraryStore(fileURL: url)
    }

    private func guest(_ vmid: Int, _ name: String, type: GuestType = .qemu) -> PVEGuest {
        PVEGuest(vmid: vmid, name: name, node: "pve1", type: type, status: "running", isTemplate: false)
    }

    func testFavoritesAreKeptInTheLibraryInLibraryOrder() throws {
        let store = newStore()
        let folder = LibraryItem.folder("Customers")
        let web = LibraryItem.sshConnection("web01", config: SSHConfig(host: "10.20.30.11"))
        let office = LibraryItem.proxmoxServer("Office", config: ProxmoxConfig(host: "10.20.31.2"))
        store.add(folder, to: nil)
        store.add(web, to: folder.id)
        store.add(office, to: nil)

        store.setFavorite(.guest(server: office.id, vmid: 201), true, guest: guest(201, "postgres"))
        store.setFavorite(.guest(server: office.id, vmid: 103), true, guest: guest(103, "gitlab", type: .lxc))
        store.setFavorite(.node(server: office.id, node: "pve1"), true)
        store.setFavorite(.item(office.id), true)
        store.setFavorite(.item(web.id), true)
        store.setFavorite(.item(folder.id), true) // folders can't be favourites

        let expected: [EntryID] = [.item(web.id), .item(office.id), .node(server: office.id, node: "pve1"),
                                   .guest(server: office.id, vmid: 103), .guest(server: office.id, vmid: 201)]
        XCTAssertEqual(store.favorites.map(\.id), expected)
        XCTAssertEqual(store.favorites.last?.name, "postgres")
        XCTAssertEqual(store.favorites.last?.serverName, "Office")
        XCTAssertEqual(store.favorites[3].guestType, .lxc)
        XCTAssertFalse(store.isFavorite(.item(folder.id)))

        // On disk, so a reload (and iCloud) has them.
        let reloaded = LibraryStore(fileURL: store.fileURL)
        XCTAssertEqual(reloaded.favorites.map(\.id), expected)

        // Removing the last one leaves no trace in the file, as older versions wrote it.
        for id in expected { store.setFavorite(id, false) }
        XCTAssertTrue(store.favorites.isEmpty)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(json.contains("favorite"), json)
    }

    func testOlderLibraryFilesStillLoad() throws {
        let json = #"{"version":2,"items":[{"id":"D0000000-0000-4000-8000-000000000001","kind":"ssh","name":"web01","children":[],"ssh":{"host":"10.20.30.11","port":22,"username":"root","auth":"key","identityFile":"","keychainHost":"","extraArgs":""}}]}"#
        let file = try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8))
        XCTAssertNil(file.items.first?.favorite)
    }

    func testMergeKeepsAFavouriteAddedOnOneSide() {
        let web = LibraryItem.sshConnection("web01", config: SSHConfig(host: "10.20.30.11"))
        let db = LibraryItem.sshConnection("db01", config: SSHConfig(host: "10.20.30.13"))
        var favourite = web
        favourite.favorite = true
        var renamed = db
        renamed.name = "db01 (old)"
        let merged = LibraryMerge.merge(base: [web, db], local: [favourite, db], remote: [web, renamed])
        XCTAssertEqual(merged.first { $0.id == web.id }?.favorite, true)
        XCTAssertEqual(merged.first { $0.id == db.id }?.name, "db01 (old)")
    }

    func testACopyIsNoFavourite() {
        let store = newStore()
        let office = LibraryItem.proxmoxServer("Office", config: ProxmoxConfig(host: "10.20.31.2"))
        store.add(office, to: nil)
        store.setFavorite(.item(office.id), true)
        store.setFavorite(.guest(server: office.id, vmid: 103), true, guest: guest(103, "gitlab"))
        store.duplicate(office.id)
        XCTAssertEqual(store.favorites.count, 2)
        XCTAssertTrue(store.favorites.allSatisfy { $0.id.serverID ?? $0.id.libraryID == office.id })
    }

    func testFavouriteGuestsFollowTheirNameInProxmox() {
        let store = newStore()
        let office = LibraryItem.proxmoxServer("Office", config: ProxmoxConfig(host: "10.20.31.2"))
        store.add(office, to: nil)
        store.setFavorite(.guest(server: office.id, vmid: 103), true, guest: guest(103, "gitlab"))
        store.updateFavoriteGuests(server: office.id, from: [guest(103, "gitlab-ce", type: .lxc), guest(104, "grafana")])
        XCTAssertEqual(store.item(office.id)?.proxmox?.favoriteGuests, [FavoriteGuest(vmid: 103, name: "gitlab-ce", type: .lxc)])
    }

    func testEntryIDsRoundTripAsStrings() {
        let server = UUID()
        for id: EntryID in [.item(UUID()), .node(server: server, node: "pve1"), .guest(server: server, vmid: 101)] {
            XCTAssertEqual(EntryID(string: id.stringValue), id)
        }
        XCTAssertNil(EntryID(string: "node:\(server.uuidString):"))
    }

    /// The sidebar shows favourites in their own group, the library below; Shortcuts and AI
    /// apps still see every entry once.
    func testSidebarGroupsFavouritesAboveTheLibrary() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/demo")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hoatzin-demo-\(UUID()).json")
        try FileManager.default.copyItem(at: docs.appendingPathComponent("library.json"), to: copy)
        urls.append(copy)
        let model = AppModel(library: LibraryStore(fileURL: copy))
        defer { try? FileManager.default.removeItem(at: model.ai.activity.fileURL) }
        model.proxmox.loadDemo(from: docs.appendingPathComponent("proxmox.json"))
        let office = try XCTUnwrap(model.library.proxmoxServers.first { $0.name == "Office" })

        XCTAssertEqual(model.sidebarTree(), model.sidebarRows(), "no groups without favourites")

        model.toggleFavorite(.guest(server: office.id, vmid: 103))
        model.toggleFavorite(.node(server: office.id, node: "pve1"))
        let tree = model.sidebarTree()
        XCTAssertEqual(tree.map(\.isGroup), [true, true])
        let favourites = try XCTUnwrap(tree.first?.children)
        XCTAssertEqual(favourites.map(\.id), [.node(server: office.id, node: "pve1"), .guest(server: office.id, vmid: 103)])
        XCTAssertTrue(favourites.allSatisfy { $0.isFavoriteCopy && !$0.isMovable && $0.children == nil })
        XCTAssertEqual(favourites.last?.detail, "Office · 10.20.30.22")
        XCTAssertEqual(tree.last?.children, model.sidebarRows())

        // A filter finds the favourite and the entry in the library, not the headings.
        let filtered = SidebarFilter.apply(tree, query: "gitlab")
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(SidebarFilter.apply(tree, query: "favorites").isEmpty)

        XCTAssertTrue(model.menuItems(for: .guest(server: office.id, vmid: 103)).contains { $0.title == String(localized: "Remove from Favorites") })
        XCTAssertTrue(model.menuItems(for: .guest(server: office.id, vmid: 104)).contains { $0.title == String(localized: "Add to Favorites") })
    }
}
