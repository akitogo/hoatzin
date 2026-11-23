import AppKit

/// Debug aids for screenshots (scripts/screenshots.sh). Need no Screen Recording permission.
///
/// * `HOATZIN_SNAPSHOT=/path/prefix` renders the app's own windows to `prefix-<n>.png` after a
///   few seconds (`HOATZIN_SNAPSHOT_DELAY`, default 3). An open sheet is written on its own
///   (`-sheet.png`) and drawn onto its window (`-composite.png`). The menu bar with shortcuts
///   goes to `prefix-menu.txt`.
/// * `HOATZIN_SNAPSHOT_SIZE=1240x760` gives the main window that content size first.
/// * `HOATZIN_APPEARANCE=light` or `dark` overrides the system appearance.
enum DebugSnapshot {
    /// True for a run that takes snapshots: the mouse, wherever it is, shouldn't change them.
    static var isActive: Bool { ProcessInfo.processInfo.environment["HOATZIN_SNAPSHOT"] != nil }

    static func scheduleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        switch environment["HOATZIN_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let size = environment["HOATZIN_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let main = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.title == "Hoatzin" }
                main?.setContentSize(NSSize(width: size[0], height: size[1]))
                main?.center()
            }
        }
        guard let prefix = environment["HOATZIN_SNAPSHOT"] else { return }
        let delay = Double(environment["HOATZIN_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let image = image(of: window) else { continue }
                save(image, to: "\(prefix)-\(index).png")
                if let sheet = window.attachedSheet, let sheetImage = self.image(of: sheet) {
                    save(sheetImage, to: "\(prefix)-\(index)-sheet.png")
                    save(composite(image, of: window, with: sheetImage, of: sheet), to: "\(prefix)-\(index)-composite.png")
                }
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

    /// The window's content including the title bar, at its backing scale.
    private static func image(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        if let layer = view.layer,
           let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            layer.render(in: ctx)
            if let image = ctx.makeImage() { return image }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The window image with the sheet drawn where it sits on screen.
    private static func composite(_ image: CGImage, of window: NSWindow, with sheetImage: CGImage, of sheet: NSWindow) -> CGImage {
        let scale = window.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let frame = CGRect(x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale,
                           width: sheet.frame.width * scale, height: sheet.frame.height * scale)
        ctx.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.35))
        ctx.draw(sheetImage, in: frame)
        return ctx.makeImage() ?? image
    }

    private static func save(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
