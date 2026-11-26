import AppKit
import HoatzinCore

/// The question at the first iCloud sync when this Mac and iCloud both have a different library
/// (see `LibrarySync.chooseFirstSync`).
@MainActor
enum FirstSyncAlert {
    static func ask() async -> LibrarySync.FirstSyncChoice? {
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
}
