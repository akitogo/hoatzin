import AppKit
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.sessions.first { $0.id == model.selectedSessionID }
        VStack(spacing: 0) {
            TabStrip()
            Divider()
            if let selected {
                SessionBar(session: selected)
                Divider()
            }
            ZStack {
                SessionStack(sessions: model.sessions, selectedID: model.selectedSessionID)
                if selected == nil {
                    OverviewView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
    }
}

// MARK: - Tabs

struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                TabButton(title: String(localized: "Overview"), symbol: "square.grid.2x2", isSelected: model.selectedSessionID == nil,
                          status: nil, onSelect: { model.selectedSessionID = nil }, onClose: nil)
                ForEach(model.sessions) { session in
                    TabButton(title: session.title, symbol: session.symbol,
                              isSelected: model.selectedSessionID == session.id,
                              status: session.isAlive,
                              onSelect: { model.selectedSessionID = session.id },
                              onClose: { model.closeSession(session.id) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 36)
        .background(.bar)
    }
}

private struct TabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let status: Bool?
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title).lineLimit(1).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            if let status {
                Circle().fill(status ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (hovering ? Color.secondary.opacity(0.10) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            if let onClose { Button("Close Tab", action: onClose) }
        }
    }
}

struct SessionBar: View {
    let session: OpenSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            switch session {
            case .terminal(let s):
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("ssh \(s.target.userAtHost)").font(.system(.callout, design: .monospaced))
                Spacer()
                if let at = s.reconnectAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Reconnecting in \(max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))) s")
                            .foregroundStyle(.secondary).font(.callout).monospacedDigit()
                    }
                    Button("Cancel") { s.stopReconnecting() }
                    Button("Connect Now") { model.reconnect(s.id) }.keyboardShortcut("r", modifiers: [.command, .shift])
                } else if case .exited(let code) = s.state {
                    Text(code.map { String(localized: "closed (exit \(Int($0)))") } ?? String(localized: "closed")).foregroundStyle(.secondary).font(.callout)
                    Button("Reconnect") { model.reconnect(s.id) }.keyboardShortcut("r", modifiers: [.command, .shift])
                }
            case .console(let s):
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(s.title).font(.callout)
                if s.isLoading { ProgressView().controlSize(.small) }
                if let error = s.error {
                    Text(error).foregroundStyle(.orange).font(.callout).lineLimit(1)
                }
                Spacer()
                Button("Reload") { model.reconnect(s.id) }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            Button("Close") { model.closeSession(session.id) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Hosts the AppKit views of all open sessions and only shows the selected one, so
/// terminals and consoles stay alive while switching tabs.
struct SessionStack: NSViewRepresentable {
    let sessions: [OpenSession]
    let selectedID: UUID?

    final class Coordinator {
        var lastSelected: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ container: NSView, context: Context) {
        let wanted = sessions.map(\.view)
        for subview in container.subviews where !wanted.contains(where: { $0 === subview }) {
            subview.removeFromSuperview()
        }
        for session in sessions {
            let view = session.view
            if view.superview !== container {
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
            view.isHidden = session.id != selectedID
        }
        container.isHidden = selectedID == nil

        if context.coordinator.lastSelected != selectedID {
            context.coordinator.lastSelected = selectedID
            if let session = sessions.first(where: { $0.id == selectedID }) {
                DispatchQueue.main.async { session.focus() }
            }
        }
    }
}
