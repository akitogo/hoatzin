import Charts
import SwiftUI
import HoatzinCore

enum AppVisibility {
    /// False while all of Hoatzin's windows are hidden, minimized, covered or on another Space:
    /// live values then pause.
    @MainActor static var isVisible: Bool { NSApp.occlusionState.contains(.visible) }
}

/// The figures, graphs and storage of one node or guest, kept while its page is shown.
@MainActor
@Observable
final class MetricsModel {
    let subject: MetricsSubject
    private(set) var status: MetricsStatus?
    private(set) var live = LiveRecorder()
    private(set) var history: [MetricSample] = []
    private(set) var historyTimeframe: MetricsTimeframe?
    private(set) var storages: [StorageUsage] = []
    /// Why the last update failed; nil after a success.
    private(set) var problem: LiveDataProblem?
    /// When the values were last updated.
    private(set) var lastSuccess: Date?
    @ObservationIgnored private var lastSlowUpdate: Date?

    init(subject: MetricsSubject) {
        self.subject = subject
    }

    func samples(for timeframe: MetricsTimeframe) -> [MetricSample] {
        if timeframe == .live { return live.samples }
        return historyTimeframe == timeframe ? history : []
    }

    /// Fetches the current values. History and storage, which Proxmox updates once a minute,
    /// come along when `force`d, for a new timeframe, or when they are a minute old.
    func update(_ runtime: ProxmoxRuntime, timeframe: MetricsTimeframe, force: Bool = false) async {
        let now = Date()
        let slow = force || (timeframe != .live && historyTimeframe != timeframe)
            || lastSlowUpdate.map { now.timeIntervalSince($0) >= 60 } ?? true
        do {
            let data = try await runtime.sessionGet(subject.server, subject.statusPath)
            if let status = subject.isNode ? MetricsParser.nodeStatus(data) : MetricsParser.guestStatus(data) {
                self.status = status
                live.record(status, at: Date())
            }
            if slow {
                lastSlowUpdate = now
                if let path = subject.historyPath(timeframe) {
                    history = MetricsParser.history(try await runtime.sessionGet(subject.server, path), node: subject.isNode)
                    historyTimeframe = timeframe
                }
                if subject.isNode {
                    storages = MetricsParser.storages(try await runtime.sessionGet(subject.server, subject.basePath + "/storage"))
                }
            }
            problem = nil
            lastSuccess = Date()
        } catch {
            guard !Task.isCancelled else { return }
            problem = LiveDataProblem(error)
            // History and storage are tried again on the next update, not a minute later.
            lastSlowUpdate = nil
        }
    }
}

/// Figures and graphs of a node or guest, updated at the interval from Settings while visible.
/// Give it `.id(subject)`, so another node or guest starts with fresh data.
struct MetricsPanel: View {
    let subject: MetricsSubject
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.proxmoxRefreshInterval) private var interval = 10.0
    @AppStorage(Prefs.metricsTimeframe) private var timeframe: MetricsTimeframe = .hour
    @State private var metrics: MetricsModel
    @State private var hover: Date?

    init(subject: MetricsSubject) {
        self.subject = subject
        _metrics = State(initialValue: MetricsModel(subject: subject))
    }

    private struct PollKey: Hashable {
        let timeframe: MetricsTimeframe
        let interval: Double
        /// A login or refresh of the server starts over right away instead of waiting for the next tick.
        let serverRefresh: Date?
    }

    var body: some View {
        let samples = metrics.samples(for: timeframe)
        let server = model.proxmox.state(subject.server)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Period", selection: $timeframe) {
                    ForEach(MetricsTimeframe.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                RefreshIntervalMenu(interval: $interval) {
                    Task { await metrics.update(model.proxmox, timeframe: timeframe, force: true) }
                }
            }
            if let problem = metrics.problem {
                LiveDataNotice(problem: problem, lastSuccess: metrics.lastSuccess, isLoggingIn: server.isLoading,
                               logIn: { Task { await model.proxmox.refresh(subject.server) } },
                               retry: { Task { await metrics.update(model.proxmox, timeframe: timeframe, force: true) } })
            }
            // Old values are dimmed while they can't be updated.
            VStack(alignment: .leading, spacing: 14) {
                if let status = metrics.status {
                    StatTiles(status: status, node: subject.isNode)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(MetricChartSpec.charts(node: subject.isNode, live: timeframe == .live)) { spec in
                        MetricChartView(spec: spec, samples: samples, timeframe: timeframe, hover: $hover)
                    }
                }
                if subject.isNode && !metrics.storages.isEmpty {
                    StorageList(storages: metrics.storages)
                }
            }
            .opacity(metrics.problem == nil ? 1 : 0.4)
        }
        .task(id: PollKey(timeframe: timeframe, interval: interval, serverRefresh: server.lastRefresh)) {
            var first = true
            while !Task.isCancelled {
                if first || AppVisibility.isVisible {
                    await metrics.update(model.proxmox, timeframe: timeframe)
                }
                first = false
                guard interval > 0 else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

/// A clearly visible note that live values can't be updated, why, and since when the shown
/// values are old, with the way out: logging in again or trying again.
struct LiveDataNotice: View {
    let problem: LiveDataProblem
    let lastSuccess: Date?
    /// The server is logging in (waiting for Touch ID or the password).
    let isLoggingIn: Bool
    let logIn: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: problem == .notLoggedIn ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isLoggingIn && problem == .notLoggedIn {
                ProgressView().controlSize(.small)
            } else if problem == .notLoggedIn {
                Button("Log In", action: logIn).buttonStyle(.borderedProminent)
            } else {
                Button("Try Again", action: retry)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
    }

    private var title: String {
        switch problem {
        case .notLoggedIn:
            return isLoggingIn ? String(localized: "Logging in to Proxmox…") : String(localized: "Not logged in to Proxmox")
        case .failed:
            return String(localized: "The values can’t be updated")
        }
    }

    private var detail: String {
        let age = lastSuccess.map {
            String(localized: "The values shown are from \($0.formatted(date: .omitted, time: .shortened)).")
        } ?? String(localized: "No values could be loaded yet.")
        switch problem {
        case .notLoggedIn where isLoggingIn:
            return String(localized: "Confirm with Touch ID or enter the password.")
        case .notLoggedIn:
            return String(localized: "A Proxmox login expires after two hours without use, for example while the Mac sleeps.") + " " + age
        case .failed(let message):
            return message + " " + age
        }
    }
}

/// "↻ 10 s": how often live values are updated, plus updating right away.
struct RefreshIntervalMenu: View {
    @Binding var interval: Double
    let refreshNow: () -> Void

    var body: some View {
        Menu {
            Picker("Update live values", selection: $interval) {
                ForEach(RefreshInterval.choices, id: \.self) { Text(RefreshInterval.label($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Update Now", action: refreshNow)
        } label: {
            Label(RefreshInterval.shortLabel(interval), systemImage: "arrow.clockwise")
        }
        .fixedSize()
        .help("How often CPU, memory and the Live graph are updated")
    }
}

private struct StatTiles: View {
    let status: MetricsStatus
    let node: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatTile(title: "CPU",
                     value: status.cpu.map(MetricUnit.percent.format) ?? "—",
                     detail: status.cpus.map { String(localized: "of \($0) CPUs") })
            StatTile(title: "Memory",
                     value: status.memUsed.map(MetricUnit.bytes.format) ?? "—",
                     detail: status.memTotal.map { String(localized: "of \(MetricUnit.bytes.format($0))") })
            if node {
                StatTile(title: "Load",
                         value: status.load.map { $0.formatted(.number.precision(.fractionLength(2))) }
                            .joined(separator: " · ").ifEmpty("—"),
                         detail: String(localized: "1, 5 and 15 minutes"))
                StatTile(title: "Root disk", value: share(status.diskUsed, of: status.diskTotal),
                         detail: usedOfTotal(status.diskUsed, status.diskTotal))
            } else if let used = status.diskUsed, let total = status.diskTotal {
                StatTile(title: "Disk", value: share(used, of: total), detail: usedOfTotal(used, total))
            } else {
                StatTile(title: "Disk", value: status.diskTotal.map(MetricsFormat.diskSize) ?? "—",
                         detail: String(localized: "size"))
            }
            StatTile(title: "Uptime",
                     value: status.running ? status.uptime.map(MetricsFormat.uptime) ?? "—" : String(localized: "Stopped"),
                     detail: nil)
        }
    }

    private func share(_ used: Double?, of total: Double?) -> String {
        guard let used, let total, total > 0 else { return "—" }
        return MetricUnit.percent.format(used / total)
    }

    private func usedOfTotal(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total else { return nil }
        return String(localized: "\(MetricsFormat.diskSize(used)) of \(MetricsFormat.diskSize(total))")
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MetricChartView: View {
    let spec: MetricChartSpec
    let samples: [MetricSample]
    let timeframe: MetricsTimeframe
    @Binding var hover: Date?

    static let colors: [Color] = [.blue, .orange]

    var body: some View {
        let points = spec.points(samples)
        let latest = samples.last { sample in spec.series.contains { sample.values[$0.key] != nil } }
        let hovered = hover.flatMap { spec.sample(near: $0, in: samples) }
        let shown = hovered ?? latest
        let ticks = spec.unit.axisValues(upTo: points.map(\.value).max() ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(spec.title).font(.callout.weight(.semibold))
                if let key = spec.total, let total = shown?.values[key] ?? samples.last?.values[key] {
                    Text("of \(spec.unit.format(total))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let hovered {
                    Text(hovered.time, format: timeframe.hoverFormat).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.colors[index]).frame(width: 8, height: 8)
                        Text(series.label).foregroundStyle(.secondary)
                        Text(shown?.values[series.key].map(spec.unit.format) ?? "—").monospacedDigit()
                    }
                }
            }
            .font(.caption)
            Chart {
                ForEach(points) { point in
                    if point.filled {
                        AreaMark(x: .value("Time", point.time), y: .value("Value", point.value),
                                 series: .value("Run", point.run), stacking: .unstacked)
                            .foregroundStyle(Self.colors[point.series].opacity(0.15))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", point.time), y: .value("Value", point.value),
                             series: .value("Run", point.run))
                        .foregroundStyle(Self.colors[point.series])
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let hovered {
                    RuleMark(x: .value("Time", hovered.time))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                if let ticks {
                    AxisMarks(position: .trailing, values: ticks) { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text(spec.unit.format(number)) } }
                    }
                } else {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text(spec.unit.format(number)) } }
                    }
                }
            }
            .modifier(TopOfScale(top: ticks?.last))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: timeframe.axisFormat)
                }
            }
            .chartXSelection(value: DebugSnapshot.isActive ? .constant(nil) : $hover)
            .frame(height: 110)
            .overlay {
                if points.isEmpty { Text("No data").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// Lets the y axis reach its last tick (memory), instead of ending just above the data.
private struct TopOfScale: ViewModifier {
    let top: Double?

    func body(content: Content) -> some View {
        if let top {
            content.chartYScale(domain: 0...top)
        } else {
            content
        }
    }
}

private struct StorageList: View {
    let storages: [StorageUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(storages) { storage in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(storage.name)
                            Text(storage.shared ? String(localized: "\(storage.type), shared") : storage.type)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        UsageBar(fraction: storage.fraction)
                        Text("\(MetricsFormat.diskSize(storage.used)) of \(MetricsFormat.diskSize(storage.total))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A thin bar for a share between 0 and 1; orange from 90 %.
struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(clamped >= 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: clamped > 0 ? max(geometry.size.width * clamped, 4) : 0)
            }
        }
        .frame(minWidth: 40, maxWidth: .infinity)
        .frame(height: 6)
    }
}

/// A usage bar with its value, for the guest table; empty while the guest is stopped.
struct UsageCell: View {
    let fraction: Double?
    let text: String?
    /// Old values that can't be updated right now are dimmed.
    var stale = false

    var body: some View {
        if let fraction, let text {
            HStack(spacing: 6) {
                UsageBar(fraction: fraction).frame(width: 44)
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            .opacity(stale ? 0.4 : 1)
        }
    }
}

extension MetricsTimeframe {
    /// The time of a hovered point.
    var hoverFormat: Date.FormatStyle {
        switch self {
        case .live: return .dateTime.hour().minute().second()
        case .hour, .day: return .dateTime.hour().minute()
        case .week, .month, .year: return .dateTime.day().month(.abbreviated).hour().minute()
        }
    }
}
