import AppKit
import CloudKit
import Observation
import Security
import SystemConfiguration

/// Keeps the library the same on all Macs signed in to the same iCloud account.
///
/// The whole library is one record in the user's private CloudKit database, in its own zone,
/// stored end-to-end encrypted (`encryptedValues`): only the user's devices can read it. Like
/// library.json it never contains a password. Each Mac remembers the library as last synced
/// (the base) and merges three ways (`LibraryMerge`), so edits made on two Macs in between are
/// both kept.
///
/// Hoatzin asks iCloud at launch, when it becomes active, every few minutes and shortly after a
/// change here; it needs no push notifications.
///
/// Builds without the iCloud entitlement (own builds without the provisioning profile, tests)
/// never touch CloudKit. A library other than the default one (HOATZIN_LIBRARY) syncs only with
/// a zone of its own (HOATZIN_SYNC_ZONE), so tests and demos never reach the real library.
@MainActor
@Observable
final class LibrarySync {
    enum Status: Equatable {
        case off
        case unavailable(String)
        case syncing
        case synced(Date)
        case failed(String)
    }

    /// What one sync does: replace this Mac's library, replace the one in iCloud, or ask first.
    struct Plan: Equatable {
        var download: [LibraryItem]? = nil
        var upload: [LibraryItem]? = nil
        var needsChoice = false
    }

    enum FirstSyncChoice: String { case merge, useICloud, useThisMac }

    nonisolated static let containerID = "iCloud.com.akitogo.Hoatzin"
    nonisolated static let recordType = "Library"
    nonisolated static let defaultZone = "Library"

    private(set) var status: Status = .off
    /// The Mac that last changed the library in iCloud.
    private(set) var lastChangedBy: String?

    /// Answers the question asked when this Mac and iCloud both have a different library.
    @ObservationIgnored var chooseFirstSync: (() async -> FirstSyncChoice?)?

    private let library: LibraryStore
    private let zoneName: String?
    private let stateURL: URL
    @ObservationIgnored private var state: State
    @ObservationIgnored private var started = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// What this Mac remembers between syncs. Not secret: the same as library.json.
    private struct State: Codable {
        var user: String?
        var zone: String?
        var zoneReady = false
        /// The library as last synced, the common ancestor for the next merge.
        var base: [LibraryItem]?
        var changeTag: String?
        var device: String?
    }

    private enum Failure: Error {
        case noAccount, restricted, temporarilyUnavailable, newerFormat, deletedInICloud, busy
    }

    init(library: LibraryStore) {
        self.library = library
        let environment = ProcessInfo.processInfo.environment
        let isDefault = library.fileURL.standardizedFileURL == LibraryStore.defaultURL.standardizedFileURL
        zoneName = environment["HOATZIN_SYNC_ZONE"].flatMap { $0.isEmpty ? nil : $0 } ?? (isDefault ? Self.defaultZone : nil)
        stateURL = isDefault
            ? library.fileURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
            : library.fileURL.deletingPathExtension().appendingPathExtension("sync-state.json")
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        lastChangedBy = state.device
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.iCloudSync) }

    /// Whether this build may use iCloud at all (see the type's description).
    var isAvailable: Bool { Self.hasCloudKitEntitlement && zoneName != nil }

    nonisolated static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) == true
    }

    nonisolated static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    // MARK: Triggers

    /// Starts syncing (once per app run): now, on activation, every 5 minutes and after changes.
    func start() {
        guard !started else { return }
        started = true
        // Debug aid: HOATZIN_SYNC_DELETE_ZONE=1 deletes a test zone (HOATZIN_SYNC_ZONE) instead of
        // syncing. Never the standard zone.
        if ProcessInfo.processInfo.environment["HOATZIN_SYNC_DELETE_ZONE"] == "1" {
            if let zoneName, zoneName != Self.defaultZone, Self.hasCloudKitEntitlement {
                Task {
                    let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
                    do {
                        try await CKContainer(identifier: Self.containerID).privateCloudDatabase.deleteRecordZone(withID: zoneID)
                        NSLog("Hoatzin: deleted the iCloud zone \(zoneName)")
                    } catch {
                        NSLog("Hoatzin: deleting the iCloud zone \(zoneName) failed: \(error)")
                    }
                    try? FileManager.default.removeItem(at: stateURL)
                }
            }
            return
        }
        library.onChange = { [weak self] in self?.libraryChanged() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastAttempt) > 60 else { return }
                self.syncNow()
            }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        }
        settingChanged()
    }

    /// The Settings switch was turned on or off.
    func settingChanged() {
        guard isEnabled else { return status = .off }
        guard Self.hasCloudKitEntitlement else {
            return status = .unavailable(String(localized: "This build of Hoatzin cannot use iCloud. The notarized app from the GitHub releases can."))
        }
        guard zoneName != nil else {
            return status = .unavailable(String(localized: "Only the standard library syncs with iCloud."))
        }
        syncNow()
    }

    func syncNow() {
        guard isEnabled, isAvailable else { return }
        if running { again = true; return }
        running = true
        lastAttempt = Date()
        retry?.cancel()
        Task {
            await run()
            running = false
            if again {
                again = false
                syncNow()
            }
        }
    }

    private func libraryChanged() {
        guard isEnabled, isAvailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    // MARK: Sync

    private func run() async {
        status = .syncing
        do {
            try await perform()
            if isEnabled { status = .synced(Date()) }
            NSLog("Hoatzin: iCloud sync done (\(library.items.count) top-level entries, last change from \(lastChangedBy ?? "-"))")
        } catch {
            handle(error)
        }
    }

    private func perform() async throws {
        guard let zoneName else { return }
        let container = CKContainer(identifier: Self.containerID)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw Failure.noAccount
        case .restricted: throw Failure.restricted
        default: throw Failure.temporarilyUnavailable
        }
        // Another iCloud account, or another zone: start over, asking again if both have a library.
        let user = try await container.userRecordID().recordName
        if state.user != user || state.zone != zoneName {
            state = State(user: user, zone: zoneName)
            saveState()
        }

        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: "library", zoneID: zoneID)
        if !state.zoneReady {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            state.zoneReady = true
            saveState()
        }

        for _ in 0..<5 {
            let local = library.items
            // Nothing changed here, and iCloud still has the version last seen: done, without downloading it.
            if let base = state.base, base == local, let tag = state.changeTag,
               try await fetch(recordID, in: database, keys: [])?.recordChangeTag == tag {
                return
            }
            let record = try await fetch(recordID, in: database, keys: nil)
            let remote = try record.map(Self.items(of:))
            var plan = Self.plan(base: state.base, local: local, remote: remote)
            if plan.needsChoice, let remote {
                guard let choice = await askFirstSync() else {
                    UserDefaults.standard.set(false, forKey: Prefs.iCloudSync)
                    status = .off
                    return
                }
                plan = Self.plan(for: choice, local: local, remote: remote)
            }
            if state.base == nil, plan.download != nil, !local.isEmpty { backUpLibrary() }

            if let upload = plan.upload {
                let outgoing = record ?? CKRecord(recordType: Self.recordType, recordID: recordID)
                outgoing.encryptedValues["library"] = try Self.encodePayload(upload)
                outgoing.encryptedValues["device"] = Self.deviceName
                do {
                    let saved = try await save(outgoing, in: database)
                    remember(upload, tag: saved.recordChangeTag, device: Self.deviceName)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    continue // Another Mac was faster: merge again with its version.
                }
            } else if let record, let remote {
                remember(remote, tag: record.recordChangeTag, device: record.encryptedValues["device"] as? String)
            }
            if let download = plan.download { apply(download, replacing: local) }
            return
        }
        throw Failure.busy
    }

    /// The record, or nil if there is none yet. Recreates a zone another Mac deleted.
    private func fetch(_ id: CKRecord.ID, in database: CKDatabase, keys: [CKRecord.FieldKey]?) async throws -> CKRecord? {
        do {
            guard let result = try await database.records(for: [id], desiredKeys: keys)[id] else { return nil }
            return try result.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: id.zoneID)], deleting: [])
            return nil
        } catch let error as CKError where error.code == .userDeletedZone {
            throw Failure.deletedInICloud
        }
    }

    /// Saves only if nobody changed the record since it was fetched (else `.serverRecordChanged`).
    private func save(_ record: CKRecord, in database: CKDatabase) async throws -> CKRecord {
        do {
            let (results, _) = try await database.modifyRecords(saving: [record], deleting: [],
                                                                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = results[record.recordID] else { throw Failure.busy }
            return try result.get()
        } catch let error as CKError where error.code == .partialFailure {
            throw error.partialErrorsByItemID?[record.recordID] ?? error
        }
    }

    private func remember(_ items: [LibraryItem], tag: String?, device: String?) {
        state.base = items
        state.changeTag = tag
        state.device = device
        saveState()
        lastChangedBy = device
    }

    /// Puts the library from iCloud in place, keeping what changed here while syncing.
    private func apply(_ incoming: [LibraryItem], replacing snapshot: [LibraryItem]) {
        let current = library.items
        if current == snapshot {
            library.replaceAll(incoming)
        } else {
            library.replaceAll(LibraryMerge.merge(base: snapshot, local: current, remote: incoming))
            again = true
        }
    }

    /// Before the first sync changes this Mac's library: a copy next to it.
    private func backUpLibrary() {
        let url = library.fileURL
        let copy = url.deletingPathExtension().appendingPathExtension("before-icloud.json")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    private func askFirstSync() async -> FirstSyncChoice? {
        if let chooseFirstSync { return await chooseFirstSync() }
        // Debug aid for tests with two libraries: HOATZIN_SYNC_CHOICE=merge, useICloud or useThisMac.
        if let choice = ProcessInfo.processInfo.environment["HOATZIN_SYNC_CHOICE"] { return FirstSyncChoice(rawValue: choice) }
        let alert = NSAlert()
        alert.messageText = String(localized: "The library in iCloud differs from the one on this Mac")
        alert.informativeText = String(localized: "Merge keeps the folders and connections of both. You can also replace this Mac’s library with the one in iCloud, or the other way round. A copy of this Mac’s library stays in the Hoatzin folder. Passwords are not affected.")
        alert.addButton(withTitle: String(localized: "Merge"))
        alert.addButton(withTitle: String(localized: "Use iCloud Library"))
        alert.addButton(withTitle: String(localized: "Use This Mac’s Library"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        // A sheet, because runModal here would hold up everything else on the main actor.
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.title == "Hoatzin" }
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        switch response {
        case .alertFirstButtonReturn: return .merge
        case .alertSecondButtonReturn: return .useICloud
        case .alertThirdButtonReturn: return .useThisMac
        default: return nil
        }
    }

    private func handle(_ error: Error) {
        NSLog("Hoatzin: iCloud sync failed: \(error)")
        switch error {
        case Failure.noAccount:
            status = .unavailable(String(localized: "Sign in to iCloud in System Settings to sync the library."))
        case Failure.restricted:
            status = .unavailable(String(localized: "iCloud is restricted on this Mac."))
        case Failure.temporarilyUnavailable:
            status = .failed(String(localized: "iCloud is temporarily unavailable. Check your Apple Account in System Settings."))
        case Failure.newerFormat:
            status = .failed(String(localized: "The library in iCloud comes from a newer Hoatzin. Update Hoatzin on this Mac to sync."))
        case Failure.deletedInICloud:
            // Deleted in System Settings → iCloud: take that as a wish to stop syncing.
            state = State()
            saveState()
            UserDefaults.standard.set(false, forKey: Prefs.iCloudSync)
            status = .unavailable(String(localized: "The library was deleted from iCloud, so sync is now off."))
        case Failure.busy:
            status = .failed(String(localized: "The library in iCloud keeps changing. Hoatzin tries again shortly."))
            scheduleRetry(after: 30)
        case let error as CKError:
            switch error.code {
            case .networkUnavailable, .networkFailure:
                status = .failed(String(localized: "Offline. Hoatzin syncs again when the connection is back."))
            case .quotaExceeded:
                status = .failed(String(localized: "Your iCloud storage is full."))
            case .notAuthenticated:
                status = .unavailable(String(localized: "Sign in to iCloud in System Settings to sync the library."))
            case .accountTemporarilyUnavailable:
                status = .failed(String(localized: "iCloud is temporarily unavailable. Check your Apple Account in System Settings."))
            default:
                status = .failed(error.localizedDescription)
            }
            if let delay = error.retryAfterSeconds { scheduleRetry(after: delay) }
        default:
            status = .failed(error.localizedDescription)
        }
    }

    private func scheduleRetry(after seconds: Double) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    private func saveState() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: [.atomic])
        } catch {
            NSLog("Hoatzin: saving the sync state failed: \(error)")
        }
    }

    // MARK: Decisions (no CloudKit, tested)

    nonisolated static func plan(base: [LibraryItem]?, local: [LibraryItem], remote: [LibraryItem]?) -> Plan {
        guard let remote else {
            // Nothing in iCloud yet, or the record was removed: this Mac's library goes up.
            return base == nil && local.isEmpty ? Plan() : Plan(upload: local)
        }
        guard let base else {
            // First sync on this Mac.
            if remote == local { return Plan() }
            if local.isEmpty { return Plan(download: remote) }
            if remote.isEmpty { return Plan(upload: local) }
            return Plan(needsChoice: true)
        }
        let merged = LibraryMerge.merge(base: base, local: local, remote: remote)
        return Plan(download: merged == local ? nil : merged, upload: merged == remote ? nil : merged)
    }

    nonisolated static func plan(for choice: FirstSyncChoice, local: [LibraryItem], remote: [LibraryItem]) -> Plan {
        switch choice {
        case .merge:
            let merged = LibraryMerge.merge(base: [], local: local, remote: remote)
            return Plan(download: merged == local ? nil : merged, upload: merged == remote ? nil : merged)
        case .useICloud: return Plan(download: remote)
        case .useThisMac: return Plan(upload: local)
        }
    }

    /// The library as stored in iCloud: library.json's format, compressed.
    nonisolated static func encodePayload(_ items: [LibraryItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(LibraryFile(items: items))
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    nonisolated static func decodePayload(_ data: Data) throws -> [LibraryItem] {
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        let file = try JSONDecoder().decode(LibraryFile.self, from: json)
        guard file.version <= LibraryFile.currentVersion else { throw Failure.newerFormat }
        return file.version < LibraryFile.currentVersion ? LibraryStore.migrate(file.items, from: file.version) : file.items
    }

    private nonisolated static func items(of record: CKRecord) throws -> [LibraryItem] {
        guard let data = record.encryptedValues["library"] as? Data else { return [] }
        return try decodePayload(data)
    }
}
