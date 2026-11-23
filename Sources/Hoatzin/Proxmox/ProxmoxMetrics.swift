import Foundation

// Usage graphs of Proxmox nodes and guests. History comes from Proxmox' own round-robin
// database (`…/rrddata`, one value per minute at best); "Live" is recorded by Hoatzin from the
// current status, at the interval set in Settings. Nothing here is stored on disk.

enum MetricsTimeframe: String, CaseIterable, Identifiable {
    case live, hour, day, week, month, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .live: return String(localized: "Live")
        case .hour: return String(localized: "Hour")
        case .day: return String(localized: "Day")
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        case .year: return String(localized: "Year")
        }
    }

    /// Time labels on the x axis.
    var axisFormat: Date.FormatStyle {
        switch self {
        case .live: return .dateTime.hour().minute().second()
        case .hour, .day: return .dateTime.hour().minute()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day().month(.abbreviated)
        case .year: return .dateTime.month(.abbreviated)
        }
    }
}

/// How often live values are fetched, in seconds; 0 = only when asked.
enum RefreshInterval {
    static let choices: [Double] = [2, 5, 10, 30, 60, 0]

    static func label(_ seconds: Double) -> String {
        switch seconds {
        case 0: return String(localized: "Manually")
        case 60: return String(localized: "Every minute")
        default: return String(localized: "Every \(Int(seconds)) seconds")
        }
    }

    static func shortLabel(_ seconds: Double) -> String {
        switch seconds {
        case 0: return String(localized: "Manual")
        case 60: return String(localized: "1 min")
        default: return String(localized: "\(Int(seconds)) s")
        }
    }
}

enum MetricKey: String, CaseIterable {
    case cpu, iowait, memUsed, memTotal, load, netIn, netOut, diskRead, diskWrite
}

struct MetricSample: Equatable {
    var time: Date
    var values: [MetricKey: Double]
}

/// A node or guest whose graphs are shown.
enum MetricsSubject: Hashable {
    case node(server: UUID, node: String)
    case guest(server: UUID, node: String, type: GuestType, vmid: Int)

    var server: UUID {
        switch self {
        case .node(let server, _), .guest(let server, _, _, _): return server
        }
    }

    var isNode: Bool {
        if case .node = self { return true }
        return false
    }

    var basePath: String {
        switch self {
        case .node(_, let node): return "/nodes/\(node)"
        case .guest(_, let node, let type, let vmid): return "/nodes/\(node)/\(type.rawValue)/\(vmid)"
        }
    }

    var statusPath: String { basePath + (isNode ? "/status" : "/status/current") }

    /// nil for Live, which Hoatzin records itself.
    func historyPath(_ timeframe: MetricsTimeframe) -> String? {
        timeframe == .live ? nil : basePath + "/rrddata?timeframe=\(timeframe.rawValue)&cf=AVERAGE"
    }
}

/// The current values of a node or guest.
struct MetricsStatus: Equatable {
    var running = true
    /// Share of `cpus` (0…1).
    var cpu: Double?
    var cpus: Int?
    var iowait: Double?
    var memUsed: Double?
    var memTotal: Double?
    /// 1, 5 and 15 minutes.
    var load: [Double] = []
    /// The node's root file system, or a container's disk. VMs only know their disk size.
    var diskUsed: Double?
    var diskTotal: Double?
    var uptime: TimeInterval?
    /// Byte counters since start (network, disk IO), turned into rates by `LiveRecorder`.
    var counters: [MetricKey: Double] = [:]

    var gauges: [MetricKey: Double] {
        var values: [MetricKey: Double] = [:]
        values[.cpu] = cpu
        values[.iowait] = iowait
        values[.memUsed] = memUsed
        values[.memTotal] = memTotal
        values[.load] = load.first
        return values
    }
}

struct StorageUsage: Identifiable, Equatable {
    var name: String
    var type: String
    var used: Double
    var total: Double
    var shared: Bool

    var id: String { name }
    var fraction: Double { total > 0 ? used / total : 0 }
}

// MARK: - Parsing the API's answers

enum MetricsParser {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    /// `GET /nodes/{node}/status`
    static func nodeStatus(_ data: Any?) -> MetricsStatus? {
        guard let json = data as? [String: Any] else { return nil }
        let memory = json["memory"] as? [String: Any]
        let rootfs = json["rootfs"] as? [String: Any]
        return MetricsStatus(
            cpu: double(json["cpu"]),
            cpus: ProxmoxClient.int((json["cpuinfo"] as? [String: Any])?["cpus"]),
            iowait: double(json["wait"]),
            memUsed: double(memory?["used"]),
            memTotal: double(memory?["total"]),
            load: (json["loadavg"] as? [Any] ?? []).compactMap(double),
            diskUsed: double(rootfs?["used"]),
            diskTotal: double(rootfs?["total"]),
            uptime: double(json["uptime"])
        )
    }

    /// `GET /nodes/{node}/{qemu|lxc}/{vmid}/status/current`
    static func guestStatus(_ data: Any?) -> MetricsStatus? {
        guard let json = data as? [String: Any] else { return nil }
        let running = json["status"] as? String == "running"
        var counters: [MetricKey: Double] = [:]
        counters[.netIn] = double(json["netin"])
        counters[.netOut] = double(json["netout"])
        counters[.diskRead] = double(json["diskread"])
        counters[.diskWrite] = double(json["diskwrite"])
        let disk = double(json["disk"])
        return MetricsStatus(
            running: running,
            cpu: running ? double(json["cpu"]) : nil,
            cpus: ProxmoxClient.int(json["cpus"]),
            memUsed: running ? double(json["mem"]) : nil,
            memTotal: double(json["maxmem"]),
            diskUsed: disk.flatMap { $0 > 0 ? $0 : nil },
            diskTotal: double(json["maxdisk"]),
            uptime: running ? double(json["uptime"]) : nil,
            counters: running ? counters : [:]
        )
    }

    private static let nodeFields: [String: MetricKey] = [
        "cpu": .cpu, "iowait": .iowait, "memused": .memUsed, "memtotal": .memTotal,
        "loadavg": .load, "netin": .netIn, "netout": .netOut,
    ]
    private static let guestFields: [String: MetricKey] = [
        "cpu": .cpu, "mem": .memUsed, "maxmem": .memTotal, "netin": .netIn, "netout": .netOut,
        "diskread": .diskRead, "diskwrite": .diskWrite,
    ]

    /// `GET …/rrddata`: one row per step; a value is missing where Proxmox has none (e.g. while
    /// a guest was stopped).
    static func history(_ data: Any?, node: Bool) -> [MetricSample] {
        let fields = node ? nodeFields : guestFields
        return (data as? [[String: Any]] ?? []).compactMap { row -> MetricSample? in
            guard let time = double(row["time"]) else { return nil }
            var values: [MetricKey: Double] = [:]
            for (field, key) in fields {
                if let value = double(row[field]), value.isFinite { values[key] = value }
            }
            return MetricSample(time: Date(timeIntervalSince1970: time), values: values)
        }
        .sorted { $0.time < $1.time }
    }

    /// `GET /nodes/{node}/storage`: active storages with a size, by name.
    static func storages(_ data: Any?) -> [StorageUsage] {
        (data as? [[String: Any]] ?? []).compactMap { entry -> StorageUsage? in
            guard let name = entry["storage"] as? String,
                  ProxmoxClient.int(entry["active"]) ?? 1 == 1,
                  let total = double(entry["total"]), total > 0
            else { return nil }
            return StorageUsage(name: name, type: entry["type"] as? String ?? "", used: double(entry["used"]) ?? 0,
                                total: total, shared: ProxmoxClient.int(entry["shared"]) == 1)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Live recording

/// The "Live" graph: current values fetched at the refresh interval, with network and disk
/// rates worked out from the byte counters of consecutive samples.
struct LiveRecorder {
    static let capacity = 180

    private(set) var samples: [MetricSample] = []
    private var previous: (time: Date, counters: [MetricKey: Double])?

    mutating func record(_ status: MetricsStatus, at time: Date) {
        var values = status.running ? status.gauges : [:]
        if status.running, let previous {
            let seconds = time.timeIntervalSince(previous.time)
            for (key, value) in status.counters {
                // A smaller counter means the guest restarted: no rate for this step.
                if seconds > 0, let old = previous.counters[key], value >= old {
                    values[key] = (value - old) / seconds
                }
            }
        }
        previous = status.running ? (time, status.counters) : nil
        samples.append(MetricSample(time: time, values: values))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
}

// MARK: - Charts

enum MetricUnit {
    case percent, bytes, bytesPerSecond, number

    func format(_ value: Double) -> String {
        switch self {
        case .percent:
            return value.formatted(.percent.precision(.fractionLength(value > 0 && value < 0.1 ? 1 : 0)))
        case .bytes:
            return Self.bytes(value, style: .memory)
        case .bytesPerSecond:
            return value < 1 ? "0" : Self.bytes(value, style: .decimal) + "/s"
        case .number:
            return value.formatted(.number.precision(.fractionLength(2)))
        }
    }

    /// "0" instead of "Zero KB", and "1 GB" instead of "1.008,8 MB" just below a binary gigabyte.
    static func bytes(_ value: Double, style: ByteCountFormatter.CountStyle) -> String {
        guard value >= 1 else { return "0" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        if style == .memory, value >= 1000 * 1_048_576, value < 1_073_741_824 {
            formatter.allowedUnits = .useGB
        }
        return formatter.string(fromByteCount: Int64(value))
    }

    /// Axis values for memory, in steps that read well in binary units (1, 2, 4, 8 … GB);
    /// nil leaves them to Swift Charts, whose decimal steps fit the other units.
    func axisValues(upTo maximum: Double) -> [Double]? {
        guard self == .bytes, maximum > 0 else { return nil }
        let steps = [1_048_576.0, 1_073_741_824, 1_099_511_627_776].flatMap { unit in
            (0..<10).map { unit * pow(2, Double($0)) }
        }
        let step = steps.first { maximum / $0 <= 3 } ?? steps.last!
        return (0...Int((maximum / step).rounded(.up))).map { Double($0) * step }
    }
}

struct MetricSeriesSpec {
    let key: MetricKey
    let label: String
    /// Drawn with a filled area below the line.
    let filled: Bool
}

struct MetricChartSpec: Identifiable {
    let id: String
    let title: String
    let unit: MetricUnit
    let series: [MetricSeriesSpec]
    /// Shown as "of …" next to the title, e.g. the memory size.
    var total: MetricKey? = nil

    /// The graphs of a node or a guest. A node's network traffic is only in Proxmox' history.
    static func charts(node: Bool, live: Bool) -> [MetricChartSpec] {
        let cpu = MetricChartSpec(id: "cpu", title: String(localized: "CPU"), unit: .percent, series: node
            ? [.init(key: .cpu, label: String(localized: "Usage"), filled: true),
               .init(key: .iowait, label: String(localized: "IO wait"), filled: false)]
            : [.init(key: .cpu, label: String(localized: "Usage"), filled: true)])
        let memory = MetricChartSpec(id: "memory", title: String(localized: "Memory"), unit: .bytes,
                                     series: [.init(key: .memUsed, label: String(localized: "Used"), filled: true)],
                                     total: .memTotal)
        let network = MetricChartSpec(id: "network", title: String(localized: "Network"), unit: .bytesPerSecond,
                                      series: [.init(key: .netIn, label: String(localized: "In"), filled: false),
                                               .init(key: .netOut, label: String(localized: "Out"), filled: false)])
        if node {
            let load = MetricChartSpec(id: "load", title: String(localized: "Load average"), unit: .number,
                                       series: [.init(key: .load, label: String(localized: "1 minute"), filled: true)])
            return live ? [cpu, memory, load] : [cpu, memory, network, load]
        }
        let disk = MetricChartSpec(id: "disk", title: String(localized: "Disk IO"), unit: .bytesPerSecond,
                                   series: [.init(key: .diskRead, label: String(localized: "Read"), filled: false),
                                            .init(key: .diskWrite, label: String(localized: "Write"), filled: false)])
        return [cpu, memory, network, disk]
    }

    struct Point: Identifiable {
        let id: Int
        /// Index into `series`.
        let series: Int
        /// Consecutive points with values; a gap starts a new run, so lines don't bridge it.
        let run: String
        let time: Date
        let value: Double
        let filled: Bool
    }

    func points(_ samples: [MetricSample]) -> [Point] {
        var points: [Point] = []
        for (index, spec) in series.enumerated() {
            var run = 0
            var inRun = false
            for sample in samples {
                guard let value = sample.values[spec.key] else {
                    if inRun { run += 1; inRun = false }
                    continue
                }
                inRun = true
                points.append(Point(id: points.count, series: index, run: "\(index)-\(run)", time: sample.time,
                                    value: value, filled: spec.filled))
            }
        }
        return points
    }

    /// The sample closest to `date` that has a value of this chart.
    func sample(near date: Date, in samples: [MetricSample]) -> MetricSample? {
        samples.filter { sample in series.contains { sample.values[$0.key] != nil } }
            .min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }
}

enum MetricsFormat {
    /// Disks and storage, in decimal units like the Finder.
    static func diskSize(_ bytes: Double) -> String {
        MetricUnit.bytes(bytes, style: .file)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? ""
    }
}
