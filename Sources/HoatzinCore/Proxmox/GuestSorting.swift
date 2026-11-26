import Foundation

/// Sorting of the guest list on a Proxmox server's page, by the clicked column. Guests without a
/// value (stopped ones for CPU and memory, ones without an address) stay at the end in both
/// directions; equal values keep the order by ID.
public struct GuestComparator: SortComparator, Hashable {
    public enum Field: String, CaseIterable {
        case status, id, name, type, node, cpu, memory, address
    }

    public var field: Field
    public var order: SortOrder = .forward

    /// As stored in the settings, e.g. "cpu:desc".
    public var rawValue: String { "\(field.rawValue):\(order == .forward ? "asc" : "desc")" }

    public init(_ field: Field, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    public init(rawValue: String) {
        let parts = rawValue.split(separator: ":").map(String.init)
        field = parts.first.flatMap(Field.init) ?? .id
        order = parts.count > 1 && parts[1] == "desc" ? .reverse : .forward
    }

    public func compare(_ lhs: PVEGuest, _ rhs: PVEGuest) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .status: result = Self.compare(lhs.isRunning ? 0 : 1, rhs.isRunning ? 0 : 1)
        case .id: result = Self.compare(lhs.vmid, rhs.vmid)
        case .name: result = lhs.name.localizedStandardCompare(rhs.name)
        case .type: result = Self.compare(lhs.type.label, rhs.type.label)
        case .node: result = lhs.node.localizedStandardCompare(rhs.node)
        case .cpu: return missingLast(lhs.cpu, rhs.cpu, lhs, rhs)
        case .memory: return missingLast(lhs.memory, rhs.memory, lhs, rhs)
        case .address: return missingLast(lhs.ips.first.map(Self.addressKey), rhs.ips.first.map(Self.addressKey), lhs, rhs)
        }
        return result == .orderedSame ? Self.compare(lhs.vmid, rhs.vmid) : directed(result)
    }

    private func directed(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func missingLast<T: Comparable>(_ a: T?, _ b: T?, _ lhs: PVEGuest, _ rhs: PVEGuest) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?):
            let result = Self.compare(a, b)
            return result == .orderedSame ? Self.compare(lhs.vmid, rhs.vmid) : directed(result)
        case (nil, nil): return Self.compare(lhs.vmid, rhs.vmid)
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// IPv4 addresses by their numbers (10.0.0.9 before 10.0.0.10), others after them as text.
    public struct AddressKey: Comparable {
        public let octets: [Int]?
        public let text: String

        public static func < (lhs: AddressKey, rhs: AddressKey) -> Bool {
            switch (lhs.octets, rhs.octets) {
            case let (a?, b?): return a.lexicographicallyPrecedes(b)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
            }
        }
    }

    public static func addressKey(_ address: String) -> AddressKey {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        return AddressKey(octets: parts.count == 4 ? parts : nil, text: address)
    }
}
