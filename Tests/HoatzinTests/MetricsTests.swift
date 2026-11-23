import XCTest
@testable import Hoatzin

final class MetricsParserTests: XCTestCase {
    func testNodeHistoryKeepsGapsAndReadsStrings() {
        let rows: [[String: Any]] = [
            ["time": 120, "cpu": 0.25, "iowait": 0.01, "loadavg": "1.5", "memused": 4e9, "memtotal": 8e9,
             "netin": 1000, "netout": 500],
            ["time": 60, "cpu": 0.5],
            ["time": 180],
        ]
        let samples = MetricsParser.history(rows, node: true)
        XCTAssertEqual(samples.map(\.time.timeIntervalSince1970), [60, 120, 180])
        XCTAssertEqual(samples[0].values, [.cpu: 0.5])
        XCTAssertEqual(samples[1].values[.load], 1.5)
        XCTAssertEqual(samples[1].values[.memTotal], 8e9)
        XCTAssertTrue(samples[2].values.isEmpty)
    }

    func testGuestHistoryUsesTheGuestFields() {
        let samples = MetricsParser.history([["time": 60, "cpu": 0.1, "mem": 1e9, "maxmem": 2e9, "diskwrite": 300]], node: false)
        XCTAssertEqual(samples.first?.values, [.cpu: 0.1, .memUsed: 1e9, .memTotal: 2e9, .diskWrite: 300])
    }

    func testNodeStatus() throws {
        let status = try XCTUnwrap(MetricsParser.nodeStatus([
            "cpu": 0.23, "wait": 0.02, "loadavg": ["2.10", "2.40", "2.20"], "uptime": 3600,
            "memory": ["used": 41e9, "total": 64e9], "rootfs": ["used": 36e9, "total": 94e9],
            "cpuinfo": ["cpus": 16],
        ] as [String: Any]))
        XCTAssertEqual(status.cpus, 16)
        XCTAssertEqual(status.load, [2.1, 2.4, 2.2])
        XCTAssertEqual(status.gauges, [.cpu: 0.23, .iowait: 0.02, .memUsed: 41e9, .memTotal: 64e9, .load: 2.1])
        XCTAssertEqual(status.diskTotal, 94e9)
    }

    func testStoppedGuestHasNoUsage() throws {
        let status = try XCTUnwrap(MetricsParser.guestStatus(["status": "stopped", "cpu": 0, "mem": 0, "maxmem": 2e9,
                                                              "netin": 5, "maxdisk": 8e9, "disk": 0] as [String: Any]))
        XCTAssertFalse(status.running)
        XCTAssertNil(status.cpu)
        XCTAssertNil(status.memUsed)
        XCTAssertNil(status.diskUsed)
        XCTAssertEqual(status.memTotal, 2e9)
        XCTAssertTrue(status.counters.isEmpty)
    }

    func testStoragesSkipInactiveAndEmptyOnes() {
        let storages = MetricsParser.storages([
            ["storage": "local-lvm", "type": "lvmthin", "active": 1, "used": 50, "total": 100],
            ["storage": "local", "type": "dir", "active": 1, "used": 10, "total": 40, "shared": 0],
            ["storage": "offline-nfs", "type": "nfs", "active": 0, "used": 0, "total": 100],
            ["storage": "pbs", "type": "pbs", "active": 1],
        ] as [[String: Any]])
        XCTAssertEqual(storages.map(\.name), ["local", "local-lvm"])
        XCTAssertEqual(storages[1].fraction, 0.5)
    }

    func testPaths() {
        let server = UUID()
        let guest = MetricsSubject.guest(server: server, node: "pve1", type: .lxc, vmid: 101)
        XCTAssertEqual(guest.statusPath, "/nodes/pve1/lxc/101/status/current")
        XCTAssertEqual(guest.historyPath(.day), "/nodes/pve1/lxc/101/rrddata?timeframe=day&cf=AVERAGE")
        XCTAssertNil(guest.historyPath(.live))
        XCTAssertEqual(MetricsSubject.node(server: server, node: "pve2").statusPath, "/nodes/pve2/status")
    }
}

final class LiveRecorderTests: XCTestCase {
    private func status(netIn: Double, running: Bool = true) -> MetricsStatus {
        MetricsStatus(running: running, cpu: running ? 0.5 : nil, counters: running ? [.netIn: netIn] : [:])
    }

    func testRatesComeFromConsecutiveCounters() {
        var recorder = LiveRecorder()
        let start = Date(timeIntervalSince1970: 1000)
        recorder.record(status(netIn: 1000), at: start)
        recorder.record(status(netIn: 21000), at: start.addingTimeInterval(10))
        XCTAssertNil(recorder.samples[0].values[.netIn])
        XCTAssertEqual(recorder.samples[1].values[.netIn], 2000)
        XCTAssertEqual(recorder.samples[1].values[.cpu], 0.5)
    }

    func testARestartOrStopLeavesAGap() {
        var recorder = LiveRecorder()
        let start = Date(timeIntervalSince1970: 1000)
        recorder.record(status(netIn: 5000), at: start)
        recorder.record(status(netIn: 100), at: start.addingTimeInterval(5))  // counter reset
        recorder.record(status(netIn: 0, running: false), at: start.addingTimeInterval(10))
        recorder.record(status(netIn: 50), at: start.addingTimeInterval(15))
        XCTAssertNil(recorder.samples[1].values[.netIn])
        XCTAssertTrue(recorder.samples[2].values.isEmpty)
        XCTAssertNil(recorder.samples[3].values[.netIn])
    }

    func testKeepsTheLatestSamplesOnly() {
        var recorder = LiveRecorder()
        for second in 0..<(LiveRecorder.capacity + 20) {
            recorder.record(status(netIn: Double(second)), at: Date(timeIntervalSince1970: Double(second)))
        }
        XCTAssertEqual(recorder.samples.count, LiveRecorder.capacity)
        XCTAssertEqual(recorder.samples.last?.time.timeIntervalSince1970, Double(LiveRecorder.capacity + 19))
    }
}

final class MetricChartTests: XCTestCase {
    func testGapsSplitALineIntoRuns() {
        let spec = MetricChartSpec.charts(node: false, live: false)[0]  // CPU
        let samples = [0.1, nil, 0.3, 0.4].enumerated().map { index, value in
            MetricSample(time: Date(timeIntervalSince1970: Double(index) * 60), values: value.map { [.cpu: $0] } ?? [:])
        }
        let points = spec.points(samples)
        XCTAssertEqual(points.map(\.run), ["0-0", "0-1", "0-1"])
        XCTAssertEqual(spec.sample(near: Date(timeIntervalSince1970: 50), in: samples)?.values[.cpu], 0.1)
    }

    func testByteFormatting() {
        XCTAssertEqual(MetricUnit.bytes.format(0), "0")
        XCTAssertEqual(MetricUnit.bytesPerSecond.format(0), "0")
        XCTAssertFalse(MetricUnit.bytes.format(1010 * 1_048_576).contains("MB"))
    }

    func testANodeHasNoLiveNetworkGraph() {
        XCTAssertEqual(MetricChartSpec.charts(node: true, live: false).map(\.id), ["cpu", "memory", "network", "load"])
        XCTAssertEqual(MetricChartSpec.charts(node: true, live: true).map(\.id), ["cpu", "memory", "load"])
        XCTAssertEqual(MetricChartSpec.charts(node: false, live: true).map(\.id), ["cpu", "memory", "network", "disk"])
    }

    func testGuestUsageFromClusterResources() {
        var guest = PVEGuest(vmid: 101, name: "nginx", node: "pve1", type: .lxc, status: "running", isTemplate: false)
        guest.applyUsage(["status": "running", "cpu": 0.25, "maxcpu": 2, "mem": 1e9, "maxmem": 2e9])
        XCTAssertEqual(guest.cpu, 0.25)
        XCTAssertEqual(guest.cpus, 2)
        guest.applyUsage(["status": "stopped", "cpu": 0, "mem": 0, "maxmem": 2e9])
        XCTAssertFalse(guest.isRunning)
        XCTAssertNil(guest.cpu)
        XCTAssertNil(guest.memory)
        XCTAssertEqual(guest.maxMemory, 2e9)
    }

    func testDemoAnswersFitTheParsers() {
        var state = ProxmoxRuntime.ServerState()
        state.guests = [PVEGuest(vmid: 101, name: "nginx", node: "pve1", type: .lxc, status: "running", isTemplate: false)]
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(MetricsParser.history(DemoMetrics.response("/nodes/pve1/rrddata?timeframe=hour&cf=AVERAGE", state: state, now: now), node: true).count, 70)
        XCTAssertNotNil(MetricsParser.nodeStatus(DemoMetrics.response("/nodes/pve1/status", state: state, now: now))?.cpu)
        XCTAssertEqual(MetricsParser.storages(DemoMetrics.response("/nodes/pve1/storage", state: state, now: now)).count, 3)
        var recorder = LiveRecorder()
        for offset in [0.0, 10] {
            let time = now.addingTimeInterval(offset)
            let status = MetricsParser.guestStatus(DemoMetrics.response("/nodes/pve1/lxc/101/status/current", state: state, now: time))
            recorder.record(try! XCTUnwrap(status), at: time)
        }
        XCTAssertGreaterThan(recorder.samples[1].values[.netIn] ?? -1, 0)
    }
}

final class GuestSortingTests: XCTestCase {
    private func guest(_ vmid: Int, _ name: String, cpu: Double? = nil, ip: String? = nil) -> PVEGuest {
        var guest = PVEGuest(vmid: vmid, name: name, node: "pve1", type: .qemu,
                             status: cpu == nil ? "stopped" : "running", isTemplate: false, ips: ip.map { [$0] } ?? [])
        guest.cpu = cpu
        return guest
    }

    private func ids(_ guests: [PVEGuest], _ comparator: GuestComparator) -> [Int] {
        guests.sorted(using: [comparator]).map(\.vmid)
    }

    func testNamesSortLikeTheFinder() {
        let guests = [guest(1, "web10"), guest(2, "Web2"), guest(3, "db")]
        XCTAssertEqual(ids(guests, GuestComparator(.name)), [3, 2, 1])
        XCTAssertEqual(ids(guests, GuestComparator(.name, order: .reverse)), [1, 2, 3])
    }

    func testStoppedGuestsStayLastForCPU() {
        let guests = [guest(1, "a", cpu: 0.2), guest(2, "b"), guest(3, "c", cpu: 0.5), guest(4, "d", cpu: 0.2)]
        XCTAssertEqual(ids(guests, GuestComparator(.cpu)), [1, 4, 3, 2])
        XCTAssertEqual(ids(guests, GuestComparator(.cpu, order: .reverse)), [3, 1, 4, 2])
    }

    func testAddressesSortByNumber() {
        let guests = [guest(1, "a", ip: "10.0.0.10"), guest(2, "b"), guest(3, "c", ip: "10.0.0.9"), guest(4, "d", ip: "host.example")]
        XCTAssertEqual(ids(guests, GuestComparator(.address)), [3, 1, 4, 2])
        XCTAssertEqual(ids(guests, GuestComparator(.address, order: .reverse)), [4, 1, 3, 2])
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(GuestComparator(rawValue: "cpu:desc"), GuestComparator(.cpu, order: .reverse))
        XCTAssertEqual(GuestComparator(rawValue: "memory:asc").rawValue, "memory:asc")
        XCTAssertEqual(GuestComparator(rawValue: "nonsense"), GuestComparator(.id))
    }
}
