import Foundation

/// The terminal's colours, the same in the Mac and the iOS app: light text on dark slate, in
/// light mode too, so a terminal looks the same wherever it is shown.
public enum TerminalTheme {
    public static let background = (red: 0.11, green: 0.12, blue: 0.14)
    /// The text, as a grey level.
    public static let foregroundWhite = 0.9
}
