import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AskpassServer.shared.start()
        ExternalTerminal.cleanupStaleScripts()
        DebugSnapshot.scheduleIfRequested()
        SecretGate.shared.startAutoLock()
        // Debug aid: HOATZIN_OPEN_ABOUT=1 opens the About panel on launch (for snapshots).
        if ProcessInfo.processInfo.environment["HOATZIN_OPEN_ABOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AboutPanel.show() }
        }
        // Debug aid: HOATZIN_OPEN_SETTINGS=1 opens Settings on launch (for snapshots).
        if ProcessInfo.processInfo.environment["HOATZIN_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // The app menu's Settings item (⌘,), whatever its title in the current language.
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
                menu.performActionForItem(at: index)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AskpassServer.shared.stop()
        ControlServer.shared.stop()
    }
}

@main
struct HoatzinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Hoatzin", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CloseCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                Button("About Hoatzin") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New SSH Connection…") { model.editor = .newItem(.ssh, parent: model.insertionFolder) }
                    .keyboardShortcut("n")
                Button("New Proxmox Server…") { model.editor = .newItem(.proxmox, parent: model.insertionFolder) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Folder…") { model.editor = .newItem(.folder, parent: model.insertionFolder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // Replaces Edit → Find, which nothing in this app uses.
            CommandGroup(replacing: .textEditing) {
                Button("Filter Sidebar") { model.filterFocusRequest += 1 }
                    .keyboardShortcut("f")
            }
            CommandMenu("Connection") {
                Button("Connect") { if let id = model.selection { model.connect(id) } }
                    .keyboardShortcut("o")
                Button("Refresh Proxmox Servers") { Task { await model.proxmox.refreshAll() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Show Overview") { model.selectedSessionID = nil }
                    .keyboardShortcut("0")
                Divider()
                Button("Lock Saved Passwords") { SecretGate.shared.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        Window("AI Activity", id: AIActivityView.windowID) {
            AIActivityView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 260)
        }
        .defaultSize(width: 920, height: 420)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Set by the main window, so ⌘W knows whether to close a tab or another window.
struct MainWindowFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var isMainWindow: Bool? {
        get { self[MainWindowFocusKey.self] }
        set { self[MainWindowFocusKey.self] = newValue }
    }
}

/// ⌘W closes the selected tab in the main window and never the window itself: closing the main
/// window quits the app. In Settings or AI Activity it closes that window. ⇧⌘W closes any window.
struct CloseCommands: Commands {
    let model: AppModel
    @FocusedValue(\.isMainWindow) private var isMainWindow

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(isMainWindow == true ? "Close Tab" : "Close") {
                guard isMainWindow == true else { return NSApp.keyWindow?.performClose(nil) ?? () }
                if let id = model.selectedSessionID { model.closeSession(id) } else { NSSound.beep() }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}
