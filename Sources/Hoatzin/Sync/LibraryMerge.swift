import Foundation

/// Three-way merge of two libraries that both started from `base` (the library as last synced),
/// entry by entry, matched by ID.
///
/// * What only one side changed is taken from that side: an entry's settings, its folder and
///   the order within a folder are looked at separately.
/// * When both sides changed the same thing, `remote` (iCloud) wins.
/// * A deletion loses against a change on the other side, so no edit is lost. A deleted folder
///   comes back if the other side put something new into it or changed something in it.
enum LibraryMerge {
    static func merge(base: [LibraryItem], local: [LibraryItem], remote: [LibraryItem]) -> [LibraryItem] {
        let b = Flat(base), l = Flat(local), r = Flat(remote)
        var content: [UUID: LibraryItem] = [:]
        var parent: [UUID: UUID?] = [:]

        // 1. Each entry: kept or deleted, its settings and its folder.
        for id in Set(b.nodes.keys).union(l.nodes.keys).union(r.nodes.keys) {
            let o = b.nodes[id], x = l.nodes[id], y = r.nodes[id]
            let kept: Node?
            switch (o, x, y) {
            case (_, nil, nil): kept = nil
            case (nil, let x?, nil): kept = x
            case (nil, _, let y?): kept = y
            case (let o?, nil, let y?): kept = y.content == o.content ? nil : y
            case (let o?, let x?, nil): kept = x.content == o.content ? nil : x
            case (let o?, let x?, let y?):
                kept = Node(content: pick(o.content, x.content, y.content), parent: pick(o.parent, x.parent, y.parent))
            }
            if let kept {
                content[id] = kept.content
                parent[id] = kept.parent
            }
        }

        // 2. Entries whose folder was deleted bring the folder back.
        var orphans = true
        while orphans {
            orphans = false
            for (id, folder) in parent.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                guard let folder, content[folder] == nil else { continue }
                orphans = true
                if let node = r.nodes[folder] ?? l.nodes[folder] ?? b.nodes[folder], node.content.kind == .folder {
                    content[folder] = node.content
                    parent[folder] = node.parent
                } else {
                    parent[id] = .some(nil)
                }
            }
        }

        // 3. Two moves can make folders contain each other; such a folder goes to the top level.
        for id in content.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var seen: Set<UUID> = []
            var next = parent[id] ?? nil
            while let current = next, !seen.contains(current) {
                if current == id { parent[id] = .some(nil); break }
                seen.insert(current)
                next = parent[current] ?? nil
            }
        }

        // 4. Order within each folder, then the tree.
        var members: [UUID?: Set<UUID>] = [:]
        for (id, folder) in parent { members[folder, default: []].insert(id) }

        func children(of folder: UUID?) -> [LibraryItem] {
            guard let ids = members[folder] else { return [] }
            return order(ids, base: b.order[folder] ?? [], local: l.order[folder] ?? [], remote: r.order[folder] ?? [])
                .compactMap { id in
                    guard var item = content[id] else { return nil }
                    item.children = children(of: id)
                    return item
                }
        }
        return children(of: nil)
    }

    /// The other side's value where one side kept the base; the remote one if both changed it.
    private static func pick<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T {
        local == base ? remote : (remote == base ? local : remote)
    }

    /// Orders the entries of one folder. Starts from the side that rearranged the folder (the
    /// remote one if both or neither did), then adds what only the other side has, each after
    /// the entry it follows there.
    private static func order(_ ids: Set<UUID>, base: [UUID], local: [UUID], remote: [UUID]) -> [UUID] {
        func rearranged(_ side: [UUID]) -> Bool {
            let common = Set(side).intersection(base)
            return side.filter(common.contains) != base.filter(common.contains)
        }
        let localFirst = rearranged(local) && !rearranged(remote)
        let primary = localFirst ? local : remote
        let secondary = localFirst ? remote : local

        var result = primary.filter(ids.contains)
        var placed = Set(result)
        for (index, id) in secondary.enumerated() where ids.contains(id) && !placed.contains(id) {
            if let previous = secondary[..<index].last(where: placed.contains), let at = result.firstIndex(of: previous) {
                result.insert(id, at: at + 1)
            } else {
                result.insert(id, at: 0)
            }
            placed.insert(id)
        }
        // Folders brought back and entries moved here from elsewhere: in their old order, at the end.
        let rest = ids.subtracting(placed).sorted { a, b in
            let ia = base.firstIndex(of: a) ?? .max, ib = base.firstIndex(of: b) ?? .max
            return ia != ib ? ia < ib : a.uuidString < b.uuidString
        }
        return result + rest
    }

    /// An entry without its children, and the folder it is in (nil = top level).
    private struct Node: Equatable {
        var content: LibraryItem
        var parent: UUID?
    }

    /// The library as a list of entries plus the order of each folder.
    private struct Flat {
        var nodes: [UUID: Node] = [:]
        var order: [UUID?: [UUID]] = [:]

        init(_ items: [LibraryItem]) { add(items, to: nil) }

        private mutating func add(_ items: [LibraryItem], to folder: UUID?) {
            order[folder] = items.map(\.id)
            for item in items {
                var content = item
                content.children = []
                nodes[item.id] = Node(content: content, parent: folder)
                add(item.children, to: item.id)
            }
        }
    }
}
