import AppKit

/// Shared editor-window configuration used by AppKit and every full-window
/// SwiftUI surface.
public enum AppWindowConfiguration {
    public static let defaultWidth: CGFloat = 1024
    public static let defaultHeight: CGFloat = 640
    public static let minWidth: CGFloat = 760
    public static let minHeight: CGFloat = 640
    public static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]
}
