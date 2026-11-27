import AppKit

// The graphs themselves are shared with the iOS app: HoatzinUI/MetricsViews.swift.

enum AppVisibility {
    /// False while all of Hoatzin's windows are hidden, minimized, covered or on another Space:
    /// live values then pause.
    @MainActor static var isVisible: Bool { NSApp.occlusionState.contains(.visible) }
}
