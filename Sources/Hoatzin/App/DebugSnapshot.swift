import AppKit

/// Debug aid: HOATZIN_SNAPSHOT=/path/prefix renders the app's own windows (and sheets) to
/// PNG files after a few seconds, and writes the menu bar with shortcuts to `prefix-menu.txt`.
/// Needs no Screen Recording permission.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        guard let prefix = ProcessInfo.processInfo.environment["HOATZIN_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["HOATZIN_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                write(window, to: "\(prefix)-\(index).png")
                if let sheet = window.attachedSheet { write(sheet, to: "\(prefix)-\(index)-sheet.png") }
            }
            if let menu = NSApp.mainMenu {
                try? describe(menu).joined(separator: "\n").write(toFile: "\(prefix)-menu.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    private static func describe(_ menu: NSMenu, depth: Int = 0) -> [String] {
        menu.items.flatMap { item -> [String] in
            if item.isSeparatorItem { return [] }
            var key = item.keyEquivalent
            if !key.isEmpty {
                let mods = item.keyEquivalentModifierMask
                key = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "")
                    + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "") + key.uppercased()
            }
            let line = String(repeating: "  ", count: depth) + item.title + (key.isEmpty ? "" : "  [\(key)]")
            return [line] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
        }
    }

    private static func write(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        if let layer = view.layer,
           let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            if !view.isFlipped {} // layers are already in their own geometry
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                return
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
