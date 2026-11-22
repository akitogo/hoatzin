import SwiftUI

/// Window → AI Activity: every call from AI apps, newest first.
struct AIActivityView: View {
    static let windowID = "ai-activity"
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.ai.activity
        let entries = Array(log.entries.reversed())
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView("No AI Activity", systemImage: "sparkles",
                                       description: Text("Calls from AI apps such as Claude appear here."))
            } else {
                Table(entries) {
                    TableColumn("Time") { entry in
                        Text(entry.time, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                            .monospacedDigit()
                    }
                    .width(min: 110, ideal: 130, max: 160)
                    TableColumn("App", value: \.app)
                        .width(min: 50, ideal: 70, max: 120)
                    TableColumn("Tool", value: \.tool)
                        .width(min: 90, ideal: 110, max: 140)
                    TableColumn("Target") { entry in
                        Text(entry.target ?? "").help(entry.target ?? "")
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Result") { entry in
                        Text(entry.outcome)
                            .foregroundStyle(entry.ok ? Color.secondary : Color.orange)
                            .help(entry.outcome)
                    }
                    .width(min: 100, ideal: 200)
                    // Last, since commands are the longest; the tooltip shows all of it.
                    TableColumn("Details") { entry in
                        Text(entry.detail ?? "")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .help(entry.detail ?? "")
                    }
                    .width(min: 120, ideal: 260)
                }
            }
            Divider()
            HStack {
                Text("Commands and typed text are kept; terminal output and passwords never are.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
                }
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
