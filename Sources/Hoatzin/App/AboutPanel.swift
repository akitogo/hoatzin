import AppKit

/// The standard About panel, with the open-source libraries Hoatzin ships and their
/// licenses. The list is generated at build time (scripts/acknowledgements.swift) into
/// Contents/Resources/Acknowledgements.json, so versions and license texts match the build.
enum AboutPanel {
    struct Library: Decodable, Equatable {
        var name: String
        var version: String
        var url: String
        var license: String
        var licenseText: String
        var purpose: String?
    }

    static func libraries(bundle: Bundle = .main) -> [Library] {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([Library].self, from: data)) ?? []
    }

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(libraries())])
    }

    static func credits(_ libraries: [Library]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 2
        let left = NSMutableParagraphStyle()
        left.alignment = .left
        left.paragraphSpacing = 2

        func add(_ string: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                 color: NSColor = .labelColor, style: NSParagraphStyle = centered, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        add(String(localized: "Open-source libraries") + "\n", weight: .semibold)
        if libraries.isEmpty {
            add(String(localized: "The list is added when the app is built with scripts/build-app.sh.") + "\n", color: .secondaryLabelColor)
        }
        for library in libraries {
            add("\n")
            add("\(library.name) \(library.version)\n", weight: .medium, link: URL(string: library.url))
            // Purposes come from scripts/acknowledgements.swift in English; translations are in Localizable.strings.
            if let purpose = library.purpose {
                add(Bundle.main.localizedString(forKey: purpose, value: purpose, table: nil) + "\n", color: .secondaryLabelColor)
            }
            add("\(library.license)\n\n", size: 10, color: .secondaryLabelColor)
            add("\(library.licenseText)\n", size: 9, color: .secondaryLabelColor, style: left)
        }

        add("\n" + String(localized: "Also used, not bundled") + "\n", weight: .semibold)
        add(String(localized: "OpenSSH (/usr/bin/ssh, part of macOS) for SSH connections.") + "\n", color: .secondaryLabelColor)
        add(String(localized: "The Proxmox VE web console (xterm.js, noVNC), loaded from your Proxmox server.") + "\n", color: .secondaryLabelColor)

        add("\n" + String(localized: "License") + "\n", weight: .semibold)
        add(String(localized: "Free software under the GNU General Public License, version 3.") + "\n",
            color: .secondaryLabelColor, link: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html"))
        add(String(localized: "The name Hoatzin and its icon are not covered by the GPL.") + "\n", color: .secondaryLabelColor)
        return text
    }
}
