import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let hoatzinItem = NSPasteboard.PasteboardType("com.akitogo.hoatzin.item")
}

/// Native source-list sidebar (NSOutlineView) with a filter field on top: remembers expanded
/// folders across launches, double-click / Return to connect, right-click menus, drag & drop
/// to reorganise.
///
/// `rows` arrive already filtered (see `SidebarFilter`). While a filter is active every branch
/// is expanded, expansion changes aren't remembered and drag & drop is off.
struct SidebarOutline: NSViewRepresentable {
    var rows: [SidebarRow]
    @Binding var filter: String
    /// Bump to move keyboard focus into the filter field (⌘F).
    var focusFilterRequest: Int
    @Binding var selection: SidebarID?
    var menuItems: (SidebarID?) -> [SidebarMenuItem]
    var onActivate: (SidebarID) -> Void
    var onMove: (UUID, UUID?, Int?) -> Void
    /// How long addresses (the grey text) are shortened.
    var addressTruncation: NSLineBreakMode = .byTruncatingHead

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let outline = KeyOutlineView()
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.allowsMultipleSelection = false
        // The column is kept at the sidebar's width (KeyOutlineView.tile); letting AppKit widen it
        // on expand only gets in the way.
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onReturn = { [weak coordinator] in coordinator?.activateSelection() }
        outline.onEscape = { [weak coordinator] in coordinator?.clearFilter() ?? false }
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.registerForDraggedTypes([.hoatzinItem])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let search = NSSearchField()
        search.placeholderString = String(localized: "Filter")
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.target = coordinator
        search.action = #selector(Coordinator.searchChanged(_:))
        search.delegate = coordinator
        search.toolTip = String(localized: "Filter by name, ID, IP or host (⌘F). ↓ moves into the list, Return connects, Esc clears.")

        let empty = NSTextField(labelWithString: String(localized: "No Matches"))
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        empty.isHidden = true

        let container = NSView()
        for view in [search, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28),
        ])

        coordinator.outline = outline
        coordinator.searchField = search
        coordinator.emptyLabel = empty
        coordinator.lastFocusRequest = focusFilterRequest
        coordinator.apply(force: true)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(force: false)
    }

    // MARK: -

    final class KeyOutlineView: NSOutlineView {
        var onReturn: (() -> Void)?
        /// Returns true if it handled Esc.
        var onEscape: (() -> Bool)?
        private var fittingColumn = false

        /// Keeps the one column exactly as wide as the sidebar. AppKit can leave it at an older
        /// width (cells then end long before their rows), and only a later resize repaired that.
        /// tile() runs on every reload, expand, collapse and frame change.
        override func tile() {
            super.tile()
            guard !fittingColumn else { return }
            fittingColumn = true
            defer { fittingColumn = false }
            sizeLastColumnToFit()
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: onReturn?()
            case 53 where onEscape?() == true: break
            default: super.keyDown(with: event)
            }
        }
    }

    final class Node: NSObject {
        var row: SidebarRow
        var children: [Node] = []
        weak var parent: Node?

        init(row: SidebarRow) { self.row = row }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
        var parent: SidebarOutline
        weak var outline: NSOutlineView?
        weak var searchField: NSSearchField?
        weak var emptyLabel: NSTextField?
        var lastFocusRequest = 0
        private var isFiltering = false
        private var roots: [Node] = []
        /// By `SidebarRow.nodeKey`: a favourite is a second node of the same entry.
        private var cache: [String: Node] = [:]
        /// By entry; the library's node where an entry is also a favourite.
        private var byID: [SidebarID: Node] = [:]
        private var lastRows: [SidebarRow] = []
        private var lastTruncation: NSLineBreakMode?
        private var applying = false
        // Folders start expanded; only the ones the user collapsed are remembered.
        private static let collapsedKey = "sidebarCollapsed"
        private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])

        init(parent: SidebarOutline) { self.parent = parent }

        // MARK: Data

        func apply(force: Bool) {
            guard let outline else { return }
            applying = true
            defer { applying = false }

            let rows = parent.rows
            let filtering = !SidebarFilter.words(parent.filter).isEmpty
            if let field = searchField, field.stringValue != parent.filter {
                field.stringValue = parent.filter
            }
            if force || rows != lastRows || filtering != isFiltering || parent.addressTruncation != lastTruncation {
                lastRows = rows
                lastTruncation = parent.addressTruncation
                isFiltering = filtering
                var used: [String: Node] = [:]
                roots = build(rows, parent: nil, used: &used)
                cache = used
                byID = [:]
                for node in used.values where !node.row.isGroup && (byID[node.row.id] == nil || !node.row.isFavoriteCopy) {
                    byID[node.row.id] = node
                }
                outline.reloadData()
                if filtering {
                    outline.expandItem(nil, expandChildren: true)
                    outline.scrollRowToVisible(0)
                } else {
                    restoreExpansion(roots)
                }
            }
            emptyLabel?.isHidden = !(filtering && rows.isEmpty)
            syncSelection(parent.selection)

            if parent.focusFilterRequest != lastFocusRequest {
                lastFocusRequest = parent.focusFilterRequest
                if let field = searchField {
                    field.window?.makeFirstResponder(field)
                    field.selectText(nil)
                }
            }
        }

        private func build(_ rows: [SidebarRow], parent: Node?, used: inout [String: Node]) -> [Node] {
            rows.map { row in
                let node = cache[row.nodeKey] ?? Node(row: row)
                node.row = row
                node.parent = parent
                used[row.nodeKey] = node
                node.children = build(row.children ?? [], parent: node, used: &used)
                return node
            }
        }

        private func restoreExpansion(_ nodes: [Node]) {
            for node in nodes where node.row.children != nil {
                if !collapsed.contains(node.row.nodeKey) {
                    outline?.expandItem(node)
                    restoreExpansion(node.children)
                } else {
                    outline?.collapseItem(node)
                }
            }
        }

        private func syncSelection(_ selection: SidebarID?) {
            guard let outline else { return }
            // A favourite stays selected where it was clicked, not in the library.
            if let selection, let current = outline.item(atRow: outline.selectedRow) as? Node, current.row.id == selection { return }
            guard let selection, let node = byID[selection] else {
                if outline.selectedRow >= 0, selection == nil { outline.deselectAll(nil) }
                return
            }
            var ancestor = node.parent
            while let a = ancestor { if !outline.isItemExpanded(a) { outline.expandItem(a) }; ancestor = a.parent }
            let row = outline.row(forItem: node)
            if row >= 0, outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.row.children != nil
        }

        /// The headings "Favorites" and "Library", as in Finder's sidebar.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node)?.row.isGroup == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.row.isGroup != true
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            if node.row.isGroup {
                let header = (outlineView.makeView(withIdentifier: SidebarGroupCell.identifier, owner: nil) as? SidebarGroupCell) ?? SidebarGroupCell()
                header.textField?.stringValue = node.row.title
                return header
            }
            let cell = (outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
            cell.configure(node.row, addressTruncation: parent.addressTruncation)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let outline else { return }
            let node = outline.item(atRow: outline.selectedRow) as? Node
            let id = node?.row.id
            if parent.selection != id { parent.selection = id }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !applying, !isFiltering, let node = notification.userInfo?["NSObject"] as? Node else { return }
            collapsed.remove(node.row.nodeKey)
            persistExpansion()
            restoreExpansion(node.children)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !applying, !isFiltering, let node = notification.userInfo?["NSObject"] as? Node else { return }
            collapsed.insert(node.row.nodeKey)
            persistExpansion()
        }

        private func persistExpansion() {
            UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
        }

        // MARK: Activation

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node, !node.row.isGroup else { return }
            if node.row.isFolder {
                sender.isItemExpanded(node) ? sender.collapseItem(node) : sender.expandItem(node)
            } else {
                parent.onActivate(node.row.id)
            }
        }

        func activateSelection() {
            guard let outline, let node = outline.item(atRow: outline.selectedRow) as? Node, !node.row.isGroup else { return }
            parent.onActivate(node.row.id)
        }

        // MARK: Filter field

        @objc func searchChanged(_ sender: NSSearchField) {
            if parent.filter != sender.stringValue { parent.filter = sender.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard control === searchField else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                focusList()
            case #selector(NSResponder.insertNewline(_:)):
                openFromFilter()
            case #selector(NSResponder.cancelOperation(_:)):
                if !clearFilter() { focusList() }
            default:
                return false
            }
            return true
        }

        /// Clears an active filter; the selection stays and is scrolled into view.
        @discardableResult
        func clearFilter() -> Bool {
            guard !parent.filter.isEmpty else { return false }
            searchField?.stringValue = ""
            parent.filter = ""
            return true
        }

        /// Connections, nodes and guests currently shown, top to bottom; favourites only where
        /// they aren't also shown in the library.
        private var visibleLeaves: [Node] {
            guard let outline else { return [] }
            let leaves = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Node }.filter { $0.row.children == nil }
            let inLibrary = Set(leaves.filter { !$0.row.isFavoriteCopy }.map(\.row.id))
            return leaves.filter { !$0.row.isFavoriteCopy || !inLibrary.contains($0.row.id) }
        }

        /// The first row that can be selected (not a group heading).
        private var firstSelectable: Node? {
            guard let outline else { return nil }
            return (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? Node }.first { !$0.row.isGroup }
        }

        private func select(_ node: Node) {
            guard let outline else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        /// ↓ in the filter field: into the list, on the first match if nothing visible is selected.
        private func focusList() {
            guard let outline else { return }
            outline.window?.makeFirstResponder(outline)
            if outline.selectedRow < 0, let first = isFiltering ? visibleLeaves.first : firstSelectable {
                select(first)
            }
        }

        /// Return in the filter field opens the selected entry if it is shown, or the only match.
        /// With several matches it selects the first one and moves into the list.
        private func openFromFilter() {
            guard let outline else { return }
            if let selected = outline.item(atRow: outline.selectedRow) as? Node, selected.row.children == nil {
                parent.onActivate(selected.row.id)
                return
            }
            let leaves = visibleLeaves
            guard let first = leaves.first else { return }
            select(first)
            if leaves.count == 1 {
                parent.onActivate(first.row.id)
            } else {
                outline.window?.makeFirstResponder(outline)
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? Node : nil
            if node?.row.isGroup == true { return }
            for entry in parent.menuItems(node?.row.id) {
                if entry.isSeparator {
                    if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                    continue
                }
                let item = ClosureMenuItem(title: entry.title, action: entry.action)
                if let symbol = entry.symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
        }

        // MARK: Drag & drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            // Positions in a filtered tree don't map to positions in the library.
            guard !isFiltering, let node = item as? Node, node.row.isMovable, let uuid = node.row.id.libraryID else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(uuid.uuidString, forType: .hoatzinItem)
            return pb
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let target = dropTarget(item: item as? Node, index: index) else { return [] }
            // Never drop a folder into itself.
            if let raw = info.draggingPasteboard.string(forType: .hoatzinItem), let dragged = UUID(uuidString: raw),
               var check = target.folder {
                while true {
                    if check.row.id.libraryID == dragged { return [] }
                    guard let up = check.parent else { break }
                    check = up
                }
            }
            // The top level of the library is below the "Library" heading when there are favourites.
            let shown = target.folder ?? libraryGroup
            if shown !== (item as? Node) || target.index != index {
                outlineView.setDropItem(shown, dropChildIndex: target.index ?? NSOutlineViewDropOnItemIndex)
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let raw = info.draggingPasteboard.string(forType: .hoatzinItem),
                  let dragged = UUID(uuidString: raw),
                  let target = dropTarget(item: item as? Node, index: index)
            else { return false }
            parent.onMove(dragged, target.folder?.row.id.libraryID, target.index)
            return true
        }

        /// The "Library" heading, when there are favourites.
        private var libraryGroup: Node? {
            roots.first { $0.row.isGroup && $0.row.id == SidebarRow.libraryGroupID }
        }

        /// The library's top level: the entries below the "Library" heading, or all roots.
        private var libraryRoots: [Node] { libraryGroup?.children ?? roots }

        /// Only library folders and the top level accept drops; dropping onto another entry
        /// inserts next to it. Favourites don't take drops. `folder` nil = the top level.
        private func dropTarget(item: Node?, index: Int) -> (folder: Node?, index: Int?)? {
            if item == nil, libraryGroup != nil { return nil } // between the headings
            guard let item, item !== libraryGroup else {
                return (nil, index == NSOutlineViewDropOnItemIndex ? libraryRoots.count : index)
            }
            if item.row.isGroup || item.row.isFavoriteCopy { return nil }
            if item.row.isFolder {
                return (item, index == NSOutlineViewDropOnItemIndex ? nil : index)
            }
            guard item.row.isMovable else { return nil } // inside a Proxmox server
            let container = item.parent === libraryGroup ? nil : item.parent
            let siblings = container?.children ?? libraryRoots
            guard let position = siblings.firstIndex(where: { $0 === item }) else { return nil }
            return (container, position + 1)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, action handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }
}

/// The heading of a group in the sidebar: "Favorites" or "Library".
final class SidebarGroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = SidebarBadge()
    private var detailBeforeBadge: NSLayoutConstraint!
    private var detailAtEdge: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for view in [icon, title, detail, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        imageView = icon
        textField = title
        detailBeforeBadge = detail.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6)
        detailAtEdge = detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailAtEdge,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { badge.isEmphasized = backgroundStyle == .emphasized }
    }

    func configure(_ row: SidebarRow, addressTruncation: NSLineBreakMode = .byTruncatingHead) {
        title.stringValue = row.title
        detail.lineBreakMode = addressTruncation
        detail.stringValue = row.detail ?? ""
        detail.isHidden = row.detail == nil
        badge.text = row.badge ?? ""
        badge.isHidden = row.badge == nil
        detailBeforeBadge.isActive = false
        detailAtEdge.isActive = false
        (row.badge == nil ? detailAtEdge : detailBeforeBadge).isActive = true
        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        switch row.tint {
        case .none: icon.contentTintColor = nil; title.textColor = .labelColor
        case .running: icon.contentTintColor = .systemGreen; title.textColor = .labelColor
        case .stopped: icon.contentTintColor = .tertiaryLabelColor; title.textColor = .secondaryLabelColor
        case .warning: icon.contentTintColor = .systemOrange; title.textColor = .labelColor
        case .accent: icon.contentTintColor = .controlAccentColor; title.textColor = .labelColor
        }
        toolTip = [row.title, row.badge.map { String(localized: "ID \($0)") }, row.detail].compactMap { $0 }.joined(separator: " — ")
    }
}

/// Rounded ID pill (Proxmox VMID), so it never reads as part of the address next to it.
/// A minimum width keeps 3- and 4-digit IDs in one column.
final class SidebarBadge: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let minimumWidth: CGFloat = {
        ceil(("0000" as NSString).size(withAttributes: [.font: font]).width) + 10
    }()

    var text = "" {
        didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    var isEmphasized = false {
        didSet { if isEmphasized != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize {
        let width = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 10
        return NSSize(width: max(width, Self.minimumWidth), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isEmphasized ? .white.withAlphaComponent(0.25) : .quaternaryLabelColor
        let ink: NSColor = isEmphasized ? .white : .secondaryLabelColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
