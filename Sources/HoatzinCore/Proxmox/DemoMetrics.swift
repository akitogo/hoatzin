import Foundation

/// Made-up API answers for demo servers (HOATZIN_DEMO_PROXMOX), so graphs and usage columns can
/// be shown and photographed without a Proxmox server. The values wander smoothly over time and
/// stay the same for the same moment, so history and live values fit together.
public enum DemoMetrics {
    public static func response(_ path: String, state: ProxmoxRuntime.ServerState?, now: Date = Date()) -> Any? {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let parts = route.split(separator: "/").map(String.init)
        let timeframe = path.components(separatedBy: "timeframe=").dropFirst().first?.split(separator: "&").first.map(String.init)

        if route == "/cluster/resources" {
            return (state?.guests ?? []).map { guest -> [String: Any] in
                let shape = Shape(guest)
                var entry: [String: Any] = ["vmid": guest.vmid, "name": guest.name, "node": guest.node,
                                            "type": guest.type.rawValue, "status": guest.status,
                                            "maxcpu": shape.cpus, "maxmem": shape.memory]
                if guest.isRunning {
                    entry["cpu"] = shape.cpu(at: now)
                    entry["mem"] = shape.memUsed(at: now)
                }
                return entry
            }
        }
        guard parts.count >= 2, parts[0] == "nodes" else { return nil }
        let node = parts[1]

        if parts.count == 3 {
            let shape = NodeShape(node)
            switch parts[2] {
            case "status": return shape.status(at: now)
            case "storage": return shape.storages
            case "rrddata": return history(timeframe, now: now) { shape.row(at: $0) }
            default: return nil
            }
        }
        if parts.count >= 5, let vmid = Int(parts[3]),
           let guest = state?.guests.first(where: { $0.vmid == vmid }) {
            let shape = Shape(guest)
            if parts[4] == "rrddata" { return history(timeframe, now: now) { shape.row(at: $0) } }
            if parts[4] == "status" { return shape.status(at: now) }
        }
        return nil
    }

    /// 70 rows like Proxmox' round-robin database: one per minute for an hour, and so on.
    private static func history(_ timeframe: String?, now: Date, row: (Date) -> [String: Any]) -> [[String: Any]] {
        let step: TimeInterval
        switch timeframe {
        case "day": step = 1800
        case "week": step = 10_800
        case "month": step = 43_200
        case "year": step = 604_800
        default: step = 60
        }
        let end = (now.timeIntervalSince1970 / step).rounded(.down) * step
        return (0..<70).map { index in
            let time = Date(timeIntervalSince1970: end - Double(69 - index) * step)
            return row(time).merging(["time": Int(time.timeIntervalSince1970)]) { _, new in new }
        }
    }

    /// A smooth wave between 0 and 1, different for each seed.
    private static func wave(_ time: Date, seed: Double) -> Double {
        let t = time.timeIntervalSince1970
        let value = 0.5 + 0.25 * sin(t / 900 + seed) + 0.15 * sin(t / 173 + seed * 3) + 0.1 * sin(t / 41 + seed * 7)
        return min(max(value, 0), 1)
    }

    /// The same number for the same name on every launch (`hashValue` changes per launch).
    private static func seed(_ name: String) -> Double {
        Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 10_007 })
    }

    private struct Shape {
        let seed: Double
        let cpus: Int
        let memory: Double
        let disk: Double
        let isContainer: Bool
        let running: Bool

        init(_ guest: PVEGuest) {
            seed = DemoMetrics.seed(guest.name)
            isContainer = guest.type == .lxc
            cpus = isContainer ? 2 : 4
            memory = (isContainer ? 2 : 8) * 1_073_741_824
            disk = (isContainer ? 16 : 64) * 1_073_741_824
            running = guest.isRunning
        }

        func cpu(at time: Date) -> Double { 0.02 + 0.4 * pow(wave(time, seed: seed), 2) }
        func memUsed(at time: Date) -> Double { memory * (0.35 + 0.3 * wave(time, seed: seed + 1)) }
        func netRate(at time: Date) -> Double { 40_000 + 2_000_000 * pow(wave(time, seed: seed + 2), 3) }
        func diskRate(at time: Date) -> Double { 10_000 + 900_000 * pow(wave(time, seed: seed + 3), 4) }

        func row(at time: Date) -> [String: Any] {
            guard running else { return [:] }
            return ["cpu": cpu(at: time), "maxcpu": cpus, "mem": memUsed(at: time), "maxmem": memory,
                    "netin": netRate(at: time), "netout": netRate(at: time) * 0.4,
                    "diskread": diskRate(at: time), "diskwrite": diskRate(at: time) * 0.6]
        }

        func status(at time: Date) -> [String: Any] {
            guard running else { return ["status": "stopped", "cpus": cpus, "maxmem": memory, "maxdisk": disk] }
            // Counters grow by about the average rate; the wave keeps the steps uneven.
            let t = time.timeIntervalSince1970
            let counter = { (rate: Double, factor: Double) in rate * factor * t + 30 * rate * factor * sin(t / 30) }
            return ["status": "running", "cpu": cpu(at: time), "cpus": cpus, "mem": memUsed(at: time), "maxmem": memory,
                    "disk": isContainer ? disk * 0.42 : 0, "maxdisk": disk, "uptime": 3_600 * 24 * 12 + Int(t) % 3_600,
                    "netin": counter(400_000, 1), "netout": counter(400_000, 0.4),
                    "diskread": counter(150_000, 1), "diskwrite": counter(150_000, 0.6)]
        }
    }

    private struct NodeShape {
        let seed: Double
        let cpus = 16
        let memory: Double = 64 * 1_073_741_824

        init(_ node: String) { seed = DemoMetrics.seed(node) }

        func row(at time: Date) -> [String: Any] {
            let busy = wave(time, seed: seed)
            return ["cpu": 0.08 + 0.35 * busy, "iowait": 0.005 + 0.03 * pow(wave(time, seed: seed + 5), 3),
                    "loadavg": 1 + 3 * busy, "memused": memory * (0.6 + 0.1 * wave(time, seed: seed + 1)),
                    "memtotal": memory, "netin": 200_000 + 6_000_000 * pow(wave(time, seed: seed + 2), 3),
                    "netout": 100_000 + 2_500_000 * pow(wave(time, seed: seed + 3), 3), "maxcpu": cpus]
        }

        func status(at time: Date) -> [String: Any] {
            let row = row(at: time)
            let load = row["loadavg"] as? Double ?? 1
            return ["cpu": row["cpu"] ?? 0, "wait": row["iowait"] ?? 0,
                    "loadavg": [load, load * 0.9, load * 0.8].map { String(format: "%.2f", $0) },
                    "memory": ["used": row["memused"] ?? 0, "total": memory],
                    "rootfs": ["used": 36 * 1_073_741_824.0, "total": 94 * 1_073_741_824.0],
                    "uptime": 3_600 * 24 * 41 + 3_600 * 3, "cpuinfo": ["cpus": cpus]]
        }

        var storages: [[String: Any]] {
            [["storage": "local", "type": "dir", "active": 1, "used": 36e9, "total": 94e9, "shared": 0],
             ["storage": "local-lvm", "type": "lvmthin", "active": 1, "used": 590e9, "total": 832e9, "shared": 0],
             ["storage": "backup", "type": "nfs", "active": 1, "used": 2.1e12, "total": 4e12, "shared": 1]]
        }
    }
}
